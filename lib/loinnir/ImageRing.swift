// SPDX-License-Identifier: BSD-3-Clause

// Images Loinnir renders into and the compositor shows (M1f2): created
// with a DRM format modifier both the driver and the compositor support,
// in exportable memory, shared as dmabufs and imported into the window.
// After rendering, an image is released to the foreign queue family (the
// compositor's) and, in v0, the CPU waits for the GPU before presenting.

import Glibc
import Todhchai

/// DRM_FORMAT_XRGB8888 is B, G, R, x in memory: VK_FORMAT_B8G8R8A8_UNORM.
let presentFormat = VK_FORMAT_B8G8R8A8_UNORM

final class ImageRing {
  struct Slot {
    var image: VkImage
    var memory: VkDeviceMemory
    var buffer: GPUBuffer
    var commands: VkCommandBuffer
    var fence: VkFence
  }

  let gpu: GPUContext
  let window: WindowID
  let width: Int32, height: Int32
  var slots: [Slot] = []
  let modifier: UInt64

  /// Three images of `width` × `height`, imported into `window`.
  init(_ gpu: GPUContext, window: WindowID, width: Int32, height: Int32, feedback: DmabufFeedback, loop: inout Loop)
    throws(LoinnirError)
  {
    self.gpu = gpu
    self.window = window
    self.width = width
    self.height = height
    let c = gpu.vk.commands

    // Modifiers the driver can render and export, that the compositor imports.
    let theirs = Set(feedback.formats.filter { $0.fourcc == DmabufFormat.xrgb8888 }.map(\.modifier))
    let ours = Self.renderableModifiers(gpu)
    let candidates = ours.filter(theirs.contains)
    guard !candidates.isEmpty else {
      throw .unsupported("\(gpu.name) and the compositor share no XRGB8888 modifier")
    }

    var chosen: UInt64 = 0
    for _ in 0..<3 {
      // The image, from the candidate modifiers.
      var image: VkImage?
      var r: VkResult = candidates.withUnsafeBufferPointer { mods in
        var list = VkImageDrmFormatModifierListCreateInfoEXT()
        list.sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT
        list.drmFormatModifierCount = UInt32(mods.count)
        list.pDrmFormatModifiers = mods.baseAddress
        return withUnsafeMutablePointer(to: &list) { lp in
          var external = VkExternalMemoryImageCreateInfo()
          external.sType = VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO
          external.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT.rawValue
          external.pNext = UnsafeRawPointer(lp)
          return withUnsafePointer(to: &external) { ep in
            var info = VkImageCreateInfo()
            info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
            info.pNext = UnsafeRawPointer(ep)
            info.imageType = VK_IMAGE_TYPE_2D
            info.format = presentFormat
            info.extent = VkExtent3D(width: UInt32(width), height: UInt32(height), depth: 1)
            info.mipLevels = 1
            info.arrayLayers = 1
            info.samples = VK_SAMPLE_COUNT_1_BIT
            info.tiling = VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT
            info.usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT.rawValue | VK_IMAGE_USAGE_TRANSFER_DST_BIT.rawValue
            info.sharingMode = VK_SHARING_MODE_EXCLUSIVE
            info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED
            return c.vkCreateImage!(gpu.device, &info, nil, &image)
          }
        }
      }
      guard r == VK_SUCCESS, let image else { throw .vulkan(.failed("vkCreateImage (dmabuf)", r)) }

      // Dedicated, exportable memory.
      var needs = VkMemoryRequirements()
      c.vkGetImageMemoryRequirements!(gpu.device, image, &needs)
      guard let type = Self.memoryType(gpu, bits: needs.memoryTypeBits) else {
        throw .unsupported("no memory type for a dmabuf image")
      }
      var memory: VkDeviceMemory?
      var dedicated = VkMemoryDedicatedAllocateInfo()
      dedicated.sType = VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO
      dedicated.image = image
      r = withUnsafePointer(to: &dedicated) { dp in
        var export = VkExportMemoryAllocateInfo()
        export.sType = VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO
        export.handleTypes = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT.rawValue
        export.pNext = UnsafeRawPointer(dp)
        return withUnsafePointer(to: &export) { xp in
          var info = VkMemoryAllocateInfo()
          info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
          info.pNext = UnsafeRawPointer(xp)
          info.allocationSize = needs.size
          info.memoryTypeIndex = type
          return c.vkAllocateMemory!(gpu.device, &info, nil, &memory)
        }
      }
      guard r == VK_SUCCESS, let memory else { throw .vulkan(.failed("vkAllocateMemory (dmabuf)", r)) }
      _ = c.vkBindImageMemory!(gpu.device, image, memory, 0)

      // The modifier the driver chose, and the plane's layout.
      var modifierProps = VkImageDrmFormatModifierPropertiesEXT()
      modifierProps.sType = VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_PROPERTIES_EXT
      _ = c.vkGetImageDrmFormatModifierPropertiesEXT!(gpu.device, image, &modifierProps)
      chosen = modifierProps.drmFormatModifier
      var subresource = VkImageSubresource()
      subresource.aspectMask = VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT.rawValue
      var layout = VkSubresourceLayout()
      c.vkGetImageSubresourceLayout!(gpu.device, image, &subresource, &layout)

      // Export it, and import it into the window.
      var fd: Int32 = -1
      var getFD = VkMemoryGetFdInfoKHR()
      getFD.sType = VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR
      getFD.memory = memory
      getFD.handleType = VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT
      r = c.vkGetMemoryFdKHR!(gpu.device, &getFD, &fd)
      guard r == VK_SUCCESS, fd >= 0 else { throw .vulkan(.failed("vkGetMemoryFdKHR", r)) }
      let buffer: GPUBuffer
      do {
        buffer = try loop.importDmabuf(window, fd: fd, width: width, height: height,
                                       format: DmabufFormat(fourcc: DmabufFormat.xrgb8888, modifier: chosen),
                                       offset: UInt32(layout.offset), stride: UInt32(layout.rowPitch))
      } catch {
        close(fd)
        throw .window(error)
      }
      close(fd)  // the compositor has its own

      // A command buffer and a fence for this image.
      var allocInfo = VkCommandBufferAllocateInfo()
      allocInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
      allocInfo.commandPool = gpu.commandPool
      allocInfo.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY
      allocInfo.commandBufferCount = 1
      var cb: VkCommandBuffer?
      _ = c.vkAllocateCommandBuffers!(gpu.device, &allocInfo, &cb)
      var fenceInfo = VkFenceCreateInfo()
      fenceInfo.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO
      var fence: VkFence?
      _ = c.vkCreateFence!(gpu.device, &fenceInfo, nil, &fence)
      slots.append(Slot(image: image, memory: memory, buffer: buffer, commands: cb!, fence: fence!))
    }
    modifier = chosen
  }

  deinit {
    let c = gpu.vk.commands
    _ = c.vkDeviceWaitIdle!(gpu.device)
    for s in slots {
      c.vkDestroyFence!(gpu.device, s.fence, nil)
      var cb: VkCommandBuffer? = s.commands
      c.vkFreeCommandBuffers!(gpu.device, gpu.commandPool, 1, &cb)
      c.vkDestroyImage!(gpu.device, s.image, nil)
      c.vkFreeMemory!(gpu.device, s.memory, nil)
    }
  }

  /// A slot the compositor isn't holding, or nil if all three are.
  func free(_ loop: borrowing Loop) -> Int? {
    slots.indices.first { !loop.isBusy(slots[$0].buffer) }
  }

  /// Records `body` into slot `i`'s command buffer between acquiring the
  /// image from the compositor and releasing it back, submits, and waits
  /// for the GPU (v0). The image is in TRANSFER_DST_OPTIMAL inside `body`.
  func render(_ i: Int, _ body: (VkCommandBuffer, VkImage) -> Void) throws(LoinnirError) {
    let c = gpu.vk.commands
    let s = slots[i]
    _ = c.vkResetCommandBuffer!(s.commands, 0)
    var begin = VkCommandBufferBeginInfo()
    begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT.rawValue
    _ = c.vkBeginCommandBuffer!(s.commands, &begin)
    barrier(s, from: VK_IMAGE_LAYOUT_UNDEFINED, to: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,
            srcFamily: VK_QUEUE_FAMILY_FOREIGN_EXT, dstFamily: gpu.queueFamily)
    body(s.commands, s.image)
    barrier(s, from: VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, to: VK_IMAGE_LAYOUT_GENERAL,
            srcFamily: gpu.queueFamily, dstFamily: VK_QUEUE_FAMILY_FOREIGN_EXT)
    _ = c.vkEndCommandBuffer!(s.commands)
    var cb: VkCommandBuffer? = s.commands
    let r: VkResult = withUnsafePointer(to: &cb) { cbp in
      var submit = VkSubmitInfo()
      submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO
      submit.commandBufferCount = 1
      submit.pCommandBuffers = cbp
      return c.vkQueueSubmit!(gpu.queue, 1, &submit, s.fence)
    }
    guard r == VK_SUCCESS else { throw .vulkan(.failed("vkQueueSubmit", r)) }
    var fence: VkFence? = s.fence
    _ = c.vkWaitForFences!(gpu.device, 1, &fence, 1, UInt64.max)
    _ = c.vkResetFences!(gpu.device, 1, &fence)
  }

  func barrier(_ s: Slot, from: VkImageLayout, to: VkImageLayout, srcFamily: UInt32, dstFamily: UInt32) {
    var b = VkImageMemoryBarrier()
    b.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
    b.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT.rawValue
    b.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT.rawValue
    b.oldLayout = from
    b.newLayout = to
    b.srcQueueFamilyIndex = srcFamily
    b.dstQueueFamilyIndex = dstFamily
    b.image = s.image
    b.subresourceRange = VkImageSubresourceRange(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, baseMipLevel: 0,
                                                 levelCount: 1, baseArrayLayer: 0, layerCount: 1)
    gpu.vk.commands.vkCmdPipelineBarrier!(s.commands, VK_PIPELINE_STAGE_ALL_COMMANDS_BIT.rawValue,
                                          VK_PIPELINE_STAGE_ALL_COMMANDS_BIT.rawValue, 0, 0, nil, 0, nil, 1, &b)
  }

  /// Single-plane modifiers the driver can render into, clear and export.
  static func renderableModifiers(_ gpu: GPUContext) -> [UInt64] {
    let c = gpu.vk.commands
    var list = VkDrmFormatModifierPropertiesListEXT()
    list.sType = VK_STRUCTURE_TYPE_DRM_FORMAT_MODIFIER_PROPERTIES_LIST_EXT
    var props = VkFormatProperties2()
    props.sType = VK_STRUCTURE_TYPE_FORMAT_PROPERTIES_2
    withUnsafeMutablePointer(to: &list) { lp in
      props.pNext = UnsafeMutableRawPointer(lp)
      c.vkGetPhysicalDeviceFormatProperties2!(gpu.physical, presentFormat, &props)
    }
    var entries = [VkDrmFormatModifierPropertiesEXT](repeating: VkDrmFormatModifierPropertiesEXT(),
                                                      count: Int(list.drmFormatModifierCount))
    entries.withUnsafeMutableBufferPointer { e in
      list.pDrmFormatModifierProperties = e.baseAddress
      withUnsafeMutablePointer(to: &list) { lp in
        props.pNext = UnsafeMutableRawPointer(lp)
        c.vkGetPhysicalDeviceFormatProperties2!(gpu.physical, presentFormat, &props)
      }
    }
    let needed = VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT.rawValue | VK_FORMAT_FEATURE_TRANSFER_DST_BIT.rawValue
    return entries.filter { $0.drmFormatModifierPlaneCount == 1 && $0.drmFormatModifierTilingFeatures & needed == needed }
      .map(\.drmFormatModifier)
  }

  /// A device-local memory type among `bits`, else any.
  static func memoryType(_ gpu: GPUContext, bits: UInt32) -> UInt32? {
    var props = VkPhysicalDeviceMemoryProperties()
    gpu.vk.commands.vkGetPhysicalDeviceMemoryProperties!(gpu.physical, &props)
    let types = withUnsafeBytes(of: props.memoryTypes) { Array($0.bindMemory(to: VkMemoryType.self)) }
    let candidates = (0..<props.memoryTypeCount).filter { bits & (1 << $0) != 0 }
    return candidates.first { types[Int($0)].propertyFlags & VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT.rawValue != 0 }
      ?? candidates.first
  }
}
