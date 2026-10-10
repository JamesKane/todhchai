// SPDX-License-Identifier: BSD-3-Clause

// The drivers devmgr knows, in order: the first rule that matches a device
// binds it.

public enum Drivers {
  public static let rules: [DriverRule] = [
    // QEMU's `edu` teaching device (docs/specs/edu.rst in QEMU): the
    // first driver, which proves a host gets its device and only it (M3g).
    .pci("edu", vendor: 0x1234, device: 0x11E8, addressBits: 28),  // edu's DMA mask
    // virtio-blk, modern and transitional (both have the modern
    // capabilities; Virtual I/O Device 1.2 §4.1.2).
    .pci("virtio-blk", vendor: 0x1AF4, device: 0x1042),
    .pci("virtio-blk", vendor: 0x1AF4, device: 0x1001),
    // The other virtio devices QEMU gives (M3k): network (modern and
    // transitional), GPU, input (keyboards, mice, tablets) and sound.
    .pci("virtio-net", vendor: 0x1AF4, device: 0x1041),
    .pci("virtio-net", vendor: 0x1AF4, device: 0x1000),
    .pci("virtio-gpu", vendor: 0x1AF4, device: 0x1050),
    .pci("virtio-input", vendor: 0x1AF4, device: 0x1052),
    .pci("virtio-sound", vendor: 0x1AF4, device: 0x1059),
  ]
}
