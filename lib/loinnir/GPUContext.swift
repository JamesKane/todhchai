// SPDX-License-Identifier: BSD-3-Clause

// The Vulkan device Loinnir renders with, on the host: the GPU the
// compositor reads dmabufs from (its feedback names it), with the
// extensions that share images as dmabufs (M1f2) and the 1.2/1.3 features
// Loinnir's API needs (M1f3).

import Glibc
import Todhchai
@_exported import Vulkan

public enum LoinnirError: Error, Equatable {
  case vulkan(VulkanError)
  case window(WindowError)
  /// No Vulkan device is the compositor's, or none can render what it takes.
  case unsupported(String)
}

public final class GPUContext {
  public let vk: VulkanLibrary
  public let instance: VkInstance
  public let physical: VkPhysicalDevice
  public let device: VkDevice
  public let queue: VkQueue
  public let queueFamily: UInt32
  public let commandPool: VkCommandPool
  public let name: String

  static let deviceExtensions = [
    "VK_KHR_external_memory_fd", "VK_EXT_external_memory_dma_buf", "VK_EXT_image_drm_format_modifier",
    "VK_EXT_queue_family_foreign", "VK_EXT_physical_device_drm",
  ]

  /// The device the compositor composites with, as `feedback` names it.
  public convenience init(matching feedback: DmabufFeedback) throws(LoinnirError) {
    try self.init(choose: .drm(feedback.mainDeviceNumbers))
  }

  /// A device with no window: the first discrete GPU, else the first one
  /// (tests and offscreen work).
  public convenience init() throws(LoinnirError) {
    try self.init(choose: .anyPreferDiscrete)
  }

  enum Choice {
    case drm((major: UInt32, minor: UInt32))
    case anyPreferDiscrete
  }

  init(choose: Choice) throws(LoinnirError) {
    do {
      vk = try VulkanLibrary()
    } catch {
      throw .vulkan(error)
    }
    var c = vk.commands

    // The instance.
    var inst: VkInstance?
    let created: VkResult = "todhchai".withCString { name in
      var app = VkApplicationInfo()
      app.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO
      app.pApplicationName = name
      app.pEngineName = name
      app.apiVersion = vulkanVersion(1, 3)
      return withUnsafePointer(to: &app) { appp in
        var info = VkInstanceCreateInfo()
        info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
        info.pApplicationInfo = appp
        return c.vkCreateInstance!(&info, nil, &inst)
      }
    }
    guard created == VK_SUCCESS, let inst else { throw .vulkan(.failed("vkCreateInstance", created)) }
    instance = inst
    vk.loadInstance(inst)
    c = vk.commands

    // The physical device: the compositor's (by DRM node), or any.
    var count: UInt32 = 0
    _ = c.vkEnumeratePhysicalDevices!(inst, &count, nil)
    var all = [VkPhysicalDevice?](repeating: nil, count: Int(count))
    _ = c.vkEnumeratePhysicalDevices!(inst, &count, &all)
    var chosen: VkPhysicalDevice?
    var chosenName = ""
    if case .anyPreferDiscrete = choose {
      let usable = all.compactMap { $0 }.filter { Self.supports(c, $0, Self.deviceExtensions) }
      func props(_ p: VkPhysicalDevice) -> VkPhysicalDeviceProperties {
        var v = VkPhysicalDeviceProperties()
        c.vkGetPhysicalDeviceProperties!(p, &v)
        return v
      }
      chosen = usable.first { props($0).deviceType == VK_PHYSICAL_DEVICE_TYPE_DISCRETE_GPU } ?? usable.first
      if let p = chosen {
        chosenName = withUnsafeBytes(of: props(p).deviceName) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
      }
    }
    let (major, minor): (UInt32, UInt32) = if case .drm(let d) = choose { (d.major, d.minor) } else { (0, 0) }
    for case let p? in all where chosen == nil {
      guard Self.supports(c, p, Self.deviceExtensions) else { continue }
      var drm = VkPhysicalDeviceDrmPropertiesEXT()
      drm.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DRM_PROPERTIES_EXT
      var props = VkPhysicalDeviceProperties2()
      props.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_PROPERTIES_2
      withUnsafeMutablePointer(to: &drm) { d in
        props.pNext = UnsafeMutableRawPointer(d)
        c.vkGetPhysicalDeviceProperties2!(p, &props)
      }
      let primary = drm.hasPrimary != 0 && UInt32(drm.primaryMajor) == major && UInt32(drm.primaryMinor) == minor
      let render = drm.hasRender != 0 && UInt32(drm.renderMajor) == major && UInt32(drm.renderMinor) == minor
      if primary || render {
        chosen = p
        chosenName = withUnsafeBytes(of: props.properties.deviceName) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        break
      }
    }
    guard let physical = chosen else {
      c.vkDestroyInstance!(inst, nil)
      throw .unsupported(major == 0 ? "no usable Vulkan device" : "no Vulkan device is the compositor's (DRM \(major):\(minor))")
    }
    self.physical = physical
    name = chosenName

    // A graphics queue.
    var families: UInt32 = 0
    c.vkGetPhysicalDeviceQueueFamilyProperties!(physical, &families, nil)
    var familyProps = [VkQueueFamilyProperties](repeating: VkQueueFamilyProperties(), count: Int(families))
    c.vkGetPhysicalDeviceQueueFamilyProperties!(physical, &families, &familyProps)
    guard let graphics = familyProps.firstIndex(where: { $0.queueFlags & VK_QUEUE_GRAPHICS_BIT.rawValue != 0 }) else {
      c.vkDestroyInstance!(inst, nil)
      throw .unsupported("\(chosenName) has no graphics queue")
    }
    queueFamily = UInt32(graphics)

    // The device, with the 1.2 and 1.3 features Loinnir uses.
    var dev: VkDevice?
    var features13 = VkPhysicalDeviceVulkan13Features()
    features13.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES
    features13.dynamicRendering = 1
    features13.synchronization2 = 1
    var features12 = VkPhysicalDeviceVulkan12Features()
    features12.sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES
    features12.bufferDeviceAddress = 1
    features12.timelineSemaphore = 1
    // The bindless texture heap (descriptor indexing).
    features12.descriptorIndexing = 1
    features12.runtimeDescriptorArray = 1
    features12.descriptorBindingPartiallyBound = 1
    features12.descriptorBindingSampledImageUpdateAfterBind = 1
    features12.shaderSampledImageArrayNonUniformIndexing = 1
    let extensionNames = Self.deviceExtensions.map { strdup($0) }
    defer { for p in extensionNames { free(p) } }
    var priority: Float = 1
    let result: VkResult = withUnsafeMutablePointer(to: &features13) { f13 in
      features12.pNext = UnsafeMutableRawPointer(f13)
      return withUnsafeMutablePointer(to: &features12) { f12 in
        withUnsafePointer(to: &priority) { pp in
          var queueInfo = VkDeviceQueueCreateInfo()
          queueInfo.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
          queueInfo.queueFamilyIndex = UInt32(graphics)
          queueInfo.queueCount = 1
          queueInfo.pQueuePriorities = pp
          return withUnsafePointer(to: &queueInfo) { qp in
            extensionNames.map { UnsafePointer($0) }.withUnsafeBufferPointer { names in
              var info = VkDeviceCreateInfo()
              info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
              info.pNext = UnsafeRawPointer(f12)
              info.queueCreateInfoCount = 1
              info.pQueueCreateInfos = qp
              info.enabledExtensionCount = UInt32(names.count)
              info.ppEnabledExtensionNames = names.baseAddress
              return c.vkCreateDevice!(physical, &info, nil, &dev)
            }
          }
        }
      }
    }
    guard result == VK_SUCCESS, let dev else {
      c.vkDestroyInstance!(inst, nil)
      throw .vulkan(.failed("vkCreateDevice on \(chosenName)", result))
    }
    device = dev
    do { try vk.loadDevice(dev) } catch { throw .vulkan(error) }
    c = vk.commands
    var q: VkQueue?
    c.vkGetDeviceQueue!(dev, UInt32(graphics), 0, &q)
    queue = q!

    var poolInfo = VkCommandPoolCreateInfo()
    poolInfo.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
    poolInfo.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT.rawValue
    poolInfo.queueFamilyIndex = UInt32(graphics)
    var pool: VkCommandPool?
    _ = c.vkCreateCommandPool!(dev, &poolInfo, nil, &pool)
    commandPool = pool!
  }

  deinit {
    let c = vk.commands
    _ = c.vkDeviceWaitIdle!(device)
    c.vkDestroyCommandPool!(device, commandPool, nil)
    c.vkDestroyDevice!(device, nil)
    c.vkDestroyInstance!(instance, nil)
  }

  /// Whether `device` has every extension in `names`.
  static func supports(_ c: VulkanCommands, _ device: VkPhysicalDevice, _ names: [String]) -> Bool {
    var count: UInt32 = 0
    _ = c.vkEnumerateDeviceExtensionProperties!(device, nil, &count, nil)
    var props = [VkExtensionProperties](repeating: VkExtensionProperties(), count: Int(count))
    _ = c.vkEnumerateDeviceExtensionProperties!(device, nil, &count, &props)
    let have = Set(props.map { p in
      withUnsafeBytes(of: p.extensionName) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    })
    return names.allSatisfy(have.contains)
  }
}
