import FSKit
import MSLFSWire

/// FSKit's vnode analog for the mslfs volume: opaque to the framework, holding
/// only the guest-issued node identity (root == 1) and its type. Attributes are
/// fetched on demand via `getattr`, never cached on the item.
final class MSLItem: FSItem {
    let nodeID: UInt64
    let itemType: FSProto.ItemType
    let name: String

    init(nodeID: UInt64, itemType: FSProto.ItemType, name: String) {
        assert(nodeID != 0, "node id must be non-zero")
        assert(!name.isEmpty, "item name must not be empty")
        self.nodeID = nodeID
        self.itemType = itemType
        self.name = name
        super.init()
    }
}
