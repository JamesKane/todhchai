// SPDX-License-Identifier: BSD-3-Clause

// Loinnir's resources (sdk.md §5): memory reached by GPU address, and
// textures as indices into one global bindless heap. There are no vertex
// buffers or descriptor sets to manage: a draw gets one root pointer, and
// shaders read everything else through it.

import Todhchai

/// Where an allocation lives.
public enum MemoryKind: Sendable {
  /// CPU-written, GPU-read: per-frame data, uploads.
  case upload
  /// GPU-only: the fastest for the GPU.
  case device
  /// GPU-written, CPU-read: results to inspect.
  case readback
}

/// GPU memory, with its address for shaders and, where the CPU can map it,
/// a pointer.
public struct GPUAllocation: @unchecked Sendable {
  public let address: UInt64
  public let pointer: UnsafeMutableRawPointer?
  public let size: Int
  let buffer: VkBuffer
  let memory: VkDeviceMemory
}

public enum TextureFormat: Sendable {
  case rgba8, bgra8, r8
  var vk: VkFormat {
    switch self {
    case .rgba8: VK_FORMAT_R8G8B8A8_UNORM
    case .bgra8: VK_FORMAT_B8G8R8A8_UNORM
    case .r8: VK_FORMAT_R8_UNORM
    }
  }
  var bytesPerPixel: Int { self == .r8 ? 1 : 4 }
}

/// A texture: `index` is its place in the heap, which shaders use.
public struct Texture: Hashable, Sendable {
  public let index: UInt32
  public let width: Int32
  public let height: Int32
  public let format: TextureFormat
}

/// An image Loinnir owns, and its current layout: an opaque handle outside
/// Loinnir (a window's backbuffer is one).
public final class ImageRecord {
  let image: VkImage
  let view: VkImageView
  let memory: VkDeviceMemory?
  let width: Int32, height: Int32
  let format: VkFormat
  var layout = VK_IMAGE_LAYOUT_UNDEFINED
  init(image: VkImage, view: VkImageView, memory: VkDeviceMemory?, width: Int32, height: Int32, format: VkFormat) {
    self.image = image
    self.view = view
    self.memory = memory
    self.width = width
    self.height = height
    self.format = format
  }
}

/// The global heap: one descriptor set holding every texture (binding 0,
/// an array of sampled images) and a linear sampler (binding 1).
final class Heap {
  static let capacity: UInt32 = 4096
  let layout: VkDescriptorSetLayout
  let pool: VkDescriptorPool
  let set: VkDescriptorSet
  let sampler: VkSampler
  var next: UInt32 = 0

  init(_ gpu: GPUContext) throws(LoinnirError) {
    let c = gpu.vk.commands
    var samplerInfo = VkSamplerCreateInfo()
    samplerInfo.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO
    samplerInfo.magFilter = VK_FILTER_LINEAR
    samplerInfo.minFilter = VK_FILTER_LINEAR
    samplerInfo.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    samplerInfo.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    samplerInfo.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE
    var s: VkSampler?
    try check(c.vkCreateSampler!(gpu.device, &samplerInfo, nil, &s), "vkCreateSampler")
    sampler = s!

    var bindings = [VkDescriptorSetLayoutBinding](repeating: VkDescriptorSetLayoutBinding(), count: 2)
    bindings[0].binding = 0
    bindings[0].descriptorType = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE
    bindings[0].descriptorCount = Self.capacity
    bindings[0].stageFlags = VK_SHADER_STAGE_ALL.rawValue
    bindings[1].binding = 1
    bindings[1].descriptorType = VK_DESCRIPTOR_TYPE_SAMPLER
    bindings[1].descriptorCount = 1
    bindings[1].stageFlags = VK_SHADER_STAGE_ALL.rawValue
    var flags: [VkDescriptorBindingFlags] = [
      VK_DESCRIPTOR_BINDING_PARTIALLY_BOUND_BIT.rawValue | VK_DESCRIPTOR_BINDING_UPDATE_AFTER_BIND_BIT.rawValue, 0,
    ]
    var l: VkDescriptorSetLayout?
    var r: VkResult = flags.withUnsafeMutableBufferPointer { fp in
      var flagInfo = VkDescriptorSetLayoutBindingFlagsCreateInfo()
      flagInfo.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_BINDING_FLAGS_CREATE_INFO
      flagInfo.bindingCount = 2
      flagInfo.pBindingFlags = UnsafePointer(fp.baseAddress)
      return withUnsafePointer(to: &flagInfo) { fip in
        bindings.withUnsafeBufferPointer { bp in
          var info = VkDescriptorSetLayoutCreateInfo()
          info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO
          info.pNext = UnsafeRawPointer(fip)
          info.flags = VK_DESCRIPTOR_SET_LAYOUT_CREATE_UPDATE_AFTER_BIND_POOL_BIT.rawValue
          info.bindingCount = 2
          info.pBindings = bp.baseAddress
          return c.vkCreateDescriptorSetLayout!(gpu.device, &info, nil, &l)
        }
      }
    }
    try check(r, "vkCreateDescriptorSetLayout")
    layout = l!

    var sizes = [VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE, descriptorCount: Self.capacity),
                 VkDescriptorPoolSize(type: VK_DESCRIPTOR_TYPE_SAMPLER, descriptorCount: 1)]
    var p: VkDescriptorPool?
    r = sizes.withUnsafeMutableBufferPointer { sp in
      var info = VkDescriptorPoolCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO
      info.flags = VK_DESCRIPTOR_POOL_CREATE_UPDATE_AFTER_BIND_BIT.rawValue
      info.maxSets = 1
      info.poolSizeCount = 2
      info.pPoolSizes = UnsafePointer(sp.baseAddress)
      return c.vkCreateDescriptorPool!(gpu.device, &info, nil, &p)
    }
    try check(r, "vkCreateDescriptorPool")
    pool = p!

    var setLayout: VkDescriptorSetLayout? = l
    var ds: VkDescriptorSet?
    let poolHandle = p
    r = withUnsafePointer(to: &setLayout) { lp in
      var info = VkDescriptorSetAllocateInfo()
      info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO
      info.descriptorPool = poolHandle
      info.descriptorSetCount = 1
      info.pSetLayouts = lp
      return c.vkAllocateDescriptorSets!(gpu.device, &info, &ds)
    }
    try check(r, "vkAllocateDescriptorSets")
    set = ds!

    var imageInfo = VkDescriptorImageInfo()
    imageInfo.sampler = s
    withUnsafePointer(to: &imageInfo) { ip in
      var write = VkWriteDescriptorSet()
      write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
      write.dstSet = ds
      write.dstBinding = 1
      write.descriptorCount = 1
      write.descriptorType = VK_DESCRIPTOR_TYPE_SAMPLER
      write.pImageInfo = ip
      c.vkUpdateDescriptorSets!(gpu.device, 1, &write, 0, nil)
    }
  }

  /// Puts `view` at the next free index; returns it.
  func add(_ gpu: GPUContext, _ view: VkImageView) -> UInt32? {
    guard next < Self.capacity else { return nil }
    let index = next
    next += 1
    var imageInfo = VkDescriptorImageInfo()
    imageInfo.imageView = view
    imageInfo.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
    withUnsafePointer(to: &imageInfo) { ip in
      var write = VkWriteDescriptorSet()
      write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET
      write.dstSet = set
      write.dstBinding = 0
      write.dstArrayElement = index
      write.descriptorCount = 1
      write.descriptorType = VK_DESCRIPTOR_TYPE_SAMPLED_IMAGE
      write.pImageInfo = ip
      gpu.vk.commands.vkUpdateDescriptorSets!(gpu.device, 1, &write, 0, nil)
    }
    return index
  }

  func destroy(_ gpu: GPUContext) {
    let c = gpu.vk.commands
    c.vkDestroyDescriptorPool!(gpu.device, pool, nil)
    c.vkDestroyDescriptorSetLayout!(gpu.device, layout, nil)
    c.vkDestroySampler!(gpu.device, sampler, nil)
  }
}

extension Loinnir {
  /// `bytes` of memory of `kind`, with its GPU address.
  public func alloc(_ kind: MemoryKind, bytes: Int) throws(LoinnirError) -> GPUAllocation {
    let c = gpu.vk.commands
    var info = VkBufferCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
    info.size = VkDeviceSize(max(bytes, 16))
    info.usage = VK_BUFFER_USAGE_SHADER_DEVICE_ADDRESS_BIT.rawValue | VK_BUFFER_USAGE_STORAGE_BUFFER_BIT.rawValue
      | VK_BUFFER_USAGE_TRANSFER_SRC_BIT.rawValue | VK_BUFFER_USAGE_TRANSFER_DST_BIT.rawValue
    info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
    var buffer: VkBuffer?
    try wrap(c.vkCreateBuffer!(gpu.device, &info, nil, &buffer), "vkCreateBuffer")
    var needs = VkMemoryRequirements()
    c.vkGetBufferMemoryRequirements!(gpu.device, buffer, &needs)
    let wanted: UInt32 = switch kind {
    case .upload: VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT.rawValue
    case .readback: VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue | VK_MEMORY_PROPERTY_HOST_CACHED_BIT.rawValue
    case .device: VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue
    }
    guard let type = memoryType(needs.memoryTypeBits, wanted)
      ?? (kind == .readback ? memoryType(needs.memoryTypeBits, VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT.rawValue) : nil)
    else {
      c.vkDestroyBuffer!(gpu.device, buffer, nil)
      throw .unsupported("no memory type for \(kind)")
    }
    var memory: VkDeviceMemory?
    var flags = VkMemoryAllocateFlagsInfo()
    flags.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_FLAGS_INFO
    flags.flags = VK_MEMORY_ALLOCATE_DEVICE_ADDRESS_BIT.rawValue
    let r: VkResult = withUnsafePointer(to: &flags) { fp in
      var a = VkMemoryAllocateInfo()
      a.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
      a.pNext = UnsafeRawPointer(fp)
      a.allocationSize = needs.size
      a.memoryTypeIndex = type
      return c.vkAllocateMemory!(gpu.device, &a, nil, &memory)
    }
    try wrap(r, "vkAllocateMemory")
    _ = c.vkBindBufferMemory!(gpu.device, buffer, memory, 0)
    var pointer: UnsafeMutableRawPointer?
    if kind != .device { _ = c.vkMapMemory!(gpu.device, memory, 0, VkDeviceSize(VK_WHOLE_SIZE), 0, &pointer) }
    var addressInfo = VkBufferDeviceAddressInfo()
    addressInfo.sType = VK_STRUCTURE_TYPE_BUFFER_DEVICE_ADDRESS_INFO
    addressInfo.buffer = buffer
    let address = c.vkGetBufferDeviceAddress!(gpu.device, &addressInfo)
    let a = GPUAllocation(address: address, pointer: pointer, size: bytes, buffer: buffer!, memory: memory!)
    allocations.append(a)
    return a
  }

  /// A texture of `format`, in the heap. With `renderTarget`, it can also
  /// be rendered into (`render(to: .texture(t))`).
  public func texture(_ format: TextureFormat, width: Int32, height: Int32, renderTarget: Bool = false)
    throws(LoinnirError) -> Texture
  {
    let c = gpu.vk.commands
    var info = VkImageCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
    info.imageType = VK_IMAGE_TYPE_2D
    info.format = format.vk
    info.extent = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
    info.mipLevels = 1
    info.arrayLayers = 1
    info.samples = VK_SAMPLE_COUNT_1_BIT
    info.tiling = VK_IMAGE_TILING_OPTIMAL
    info.usage = VK_IMAGE_USAGE_SAMPLED_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue
      | VK_IMAGE_USAGE_TRANSFER_SRC_BIT.rawValue | (renderTarget ? VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue : 0)
    info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
    var image: VkImage?
    try wrap(c.vkCreateImage!(gpu.device, &info, nil, &image), "vkCreateImage")
    var needs = VkMemoryRequirements()
    c.vkGetImageMemoryRequirements!(gpu.device, image, &needs)
    guard let type = memoryType(needs.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue) else {
      throw .unsupported("no device-local memory for a texture")
    }
    var a = VkMemoryAllocateInfo()
    a.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
    a.allocationSize = needs.size
    a.memoryTypeIndex = type
    var memory: VkDeviceMemory?
    try wrap(c.vkAllocateMemory!(gpu.device, &a, nil, &memory), "vkAllocateMemory")
    _ = c.vkBindImageMemory!(gpu.device, image, memory, 0)
    let view = try makeView(image!, format.vk)
    guard let index = heap.add(gpu, view) else { throw .unsupported("the texture heap is full") }
    textures[index] = ImageRecord(image: image!, view: view, memory: memory, width: width, height: height, format: format.vk)
    return Texture(index: index, width: width, height: height, format: format)
  }

  func makeView(_ image: VkImage, _ format: VkFormat) throws(LoinnirError) -> VkImageView {
    var info = VkImageViewCreateInfo()
    info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO
    info.image = image
    info.viewType = VK_IMAGE_VIEW_TYPE_2D
    info.format = format
    info.subresourceRange = VkImageSubresourceRange(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, baseMipLevel: 0,
                                                    levelCount: 1, baseArrayLayer: 0, layerCount: 1)
    var view: VkImageView?
    try wrap(gpu.vk.commands.vkCreateImageView!(gpu.device, &info, nil, &view), "vkCreateImageView")
    return view!
  }

  func memoryType(_ bits: UInt32, _ wanted: UInt32) -> UInt32? {
    var props = VkPhysicalDeviceMemoryProperties()
    gpu.vk.commands.vkGetPhysicalDeviceMemoryProperties!(gpu.physical, &props)
    let types = withUnsafeBytes(of: props.memoryTypes) { Array($0.bindMemory(to: VkMemoryType.self)) }
    return (0..<props.memoryTypeCount).first { bits & (1 << $0) != 0 && types[Int($0)].propertyFlags & wanted == wanted }
  }

  func wrap(_ r: VkResult, _ what: String) throws(LoinnirError) {
    guard r == VK_SUCCESS else { throw .vulkan(.failed(what, r)) }
  }
}

/// Throws a Vulkan failure as a Loinnir error.
func check(_ r: VkResult, _ what: String) throws(LoinnirError) {
  guard r == VK_SUCCESS else { throw .vulkan(.failed(what, r)) }
}
