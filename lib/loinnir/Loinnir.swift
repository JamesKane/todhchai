// SPDX-License-Identifier: BSD-3-Clause

// Loinnir (sdk.md §5): the SDK's GPU library over Vulkan. This file is the
// entry point; M1f2 gives it a device and images in a window, and M1f3 the
// drawing API.

import Todhchai

public final class Loinnir {
  public let gpu: GPUContext
  public let window: WindowID
  var ring: ImageRing?

  /// The GPU the compositor uses, for drawing into `window`.
  public static func open(window: WindowID, loop: inout Loop) throws(LoinnirError) -> Loinnir {
    let feedback: DmabufFeedback
    do {
      feedback = try loop.dmabufFeedback()
    } catch {
      throw .window(error)
    }
    return Loinnir(gpu: try GPUContext(matching: feedback), window: window, feedback: feedback)
  }

  let feedback: DmabufFeedback

  init(gpu: GPUContext, window: WindowID, feedback: DmabufFeedback) {
    self.gpu = gpu
    self.window = window
    self.feedback = feedback
  }

  /// The DRM format modifier the window's images use (once made).
  public var modifier: UInt64? { ring?.modifier }

  /// Clears a frame to `color` (red, green, blue, alpha in 0…1) on the GPU
  /// and presents it, for the configuration `config`. False if every image
  /// is still with the compositor (draw on the next frame).
  @discardableResult
  public func clear(_ color: (Float, Float, Float, Float), loop: inout Loop, config: Configure) throws(LoinnirError)
    -> Bool
  {
    if ring == nil || ring!.width != config.pixelWidth || ring!.height != config.pixelHeight {
      ring = nil
      loop.releaseGPUBuffers(window)
      ring = try ImageRing(gpu, window: window, width: config.pixelWidth, height: config.pixelHeight,
                           feedback: feedback, loop: &loop)
    }
    guard let ring, let i = ring.free(loop) else { return false }
    let c = gpu.vk.commands
    try ring.render(i) { cb, image in
      var value = VkClearColorValue()
      value.float32 = (color.0, color.1, color.2, color.3)
      var range = VkImageSubresourceRange(aspectMask: VK_IMAGE_ASPECT_COLOR_BIT.rawValue, baseMipLevel: 0,
                                          levelCount: 1, baseArrayLayer: 0, layerCount: 1)
      c.vkCmdClearColorImage!(cb, image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, &value, 1, &range)
    }
    do {
      try loop.present(window, gpuBuffer: ring.slots[i].buffer, configSeq: config.configSeq)
    } catch {
      throw .window(error)
    }
    return true
  }
}
