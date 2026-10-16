"""Create Finder metadata and bind its background alias to the actual HFS image.

The image is built without mounting it. Only this image's own catalog and
background metadata are accessed; no system volumes are opened or changed.
"""
from pathlib import Path
import datetime
import io
import struct
import sys

sys.path.insert(0, str(Path(__file__).parent / "vendor"))
from ds_store import DSStore
from mac_alias import Alias, VolumeInfo, TargetInfo

NAME = "ControlFlip"
BACKGROUND = ".background.tiff"
MAC_EPOCH = datetime.datetime(1904, 1, 1, tzinfo=datetime.timezone.utc)


def background_alias(volume_created=0, target_created=0, cnid=0xFFFFFFFF):
    volume = VolumeInfo(NAME, MAC_EPOCH + datetime.timedelta(seconds=volume_created), b"H+", 5, 0, b"\0\0",
                        posix_path="/Volumes/" + NAME)
    target = TargetInfo(0, BACKGROUND, 2, cnid, MAC_EPOCH + datetime.timedelta(seconds=target_created),
                        b"\0" * 4, b"TIFF", folder_name=NAME, cnid_path=[],
                        carbon_path=NAME + ":" + BACKGROUND, posix_path="/" + BACKGROUND)
    return Alias(volume=volume, target=target).to_bytes()


def write_layout(path, alias):
    with DSStore.open(str(path), "w+") as store:
        store["."]["vSrn"] = ("long", 1)
        store["."]["icvl"] = ("type", b"icnv")
        store["."]["bwsp"] = {
            "WindowBounds": "{{180, 100}, {760, 470}}", "ShowStatusBar": False,
            "ShowToolbar": False, "ShowSidebar": False, "ContainerShowSidebar": False,
            "ShowPathbar": False, "ShowTabView": False, "PreviewPaneVisibility": False,
            "SidebarWidth": 0,
        }
        store["."]["icvp"] = {
            "viewOptionsVersion": 1, "backgroundType": 2, "backgroundImageAlias": alias,
            "backgroundColorRed": 0.97, "backgroundColorGreen": 0.98, "backgroundColorBlue": 1.0,
            "gridOffsetX": 0.0, "gridOffsetY": 0.0, "gridSpacing": 100.0,
            "arrangeBy": "none", "showIconPreview": False, "showItemInfo": False,
            "labelOnBottom": True, "textSize": 16.0, "iconSize": 128.0,
            "scrollPositionX": 0.0, "scrollPositionY": 0.0,
        }
        store["ControlFlip.app"]["Iloc"] = (210, 220)
        store["Программы"]["Iloc"] = (550, 220)


class HFSImage:
    def __init__(self, path):
        self.path = Path(path)
        self.data = self.path.read_bytes()
        if self.data[512:514] != b"PM":
            raise ValueError("Expected an Apple Partition Map")
        partition_count = struct.unpack_from(">I", self.data, 512 + 4)[0]
        for i in range(1, partition_count + 1):
            entry = self.data[i*512:(i+1)*512]
            if entry[48:80].rstrip(b"\0") == b"Apple_HFS":
                self.base = struct.unpack_from(">I", entry, 8)[0] * 512
                break
        else:
            raise ValueError("Missing HFS partition")
        self.header = self.base + 1024
        if self.data[self.header:self.header+2] not in (b"H+", b"HX"):
            raise ValueError("Expected HFS+")
        self.created = struct.unpack_from(">I", self.data, self.header + 16)[0]
        self.block_size = struct.unpack_from(">I", self.data, self.header + 40)[0]
        self.catalog_fork = self.parse_fork(self.data, self.header + 272)
        self.catalog = self.read_fork(self.catalog_fork)
        node_size = struct.unpack_from(">H", self.catalog, 32)[0]
        leaf = struct.unpack_from(">I", self.catalog, 24)[0]
        self.records = {}
        while leaf:
            start = leaf * node_size
            node = self.catalog[start:start+node_size]
            if len(node) != node_size or node[8] != 0xFF:
                raise ValueError("Invalid HFS catalog leaf")
            record_count = struct.unpack_from(">H", node, 10)[0]
            for i in range(record_count):
                offset = struct.unpack_from(">H", node, node_size - 2*(i+1))[0]
                key_length, parent, name_length = struct.unpack_from(">HIH", node, offset)
                name = node[offset+8:offset+8+2*name_length].decode("utf-16be")
                record_start = offset + 2 + key_length
                kind = struct.unpack_from(">H", node, record_start)[0]
                if kind not in (1, 2):
                    continue
                identifier, created = struct.unpack_from(">II", node, record_start + 8)
                self.records[(parent, name)] = {
                    "kind": kind, "id": identifier, "created": created,
                    "catalog_offset": start + record_start,
                    "fork": self.parse_fork(node, record_start + 88) if kind == 2 else None,
                }
            leaf = struct.unpack_from(">I", node, 0)[0]

    @staticmethod
    def parse_fork(data, offset):
        size = struct.unpack_from(">Q", data, offset)[0]
        extents = [struct.unpack_from(">II", data, offset+16+i*8) for i in range(8)]
        return {"size": size, "extents": [(block, count) for block, count in extents if count]}

    def read_fork(self, fork):
        chunks = [self.data[self.base + block*self.block_size:self.base+(block+count)*self.block_size]
                  for block, count in fork["extents"]]
        data = b"".join(chunks)
        if len(data) < fork["size"]:
            raise ValueError("Overflow extents are not supported for installer metadata")
        return data[:fork["size"]]

    def write_fork_at(self, fork, offset, value):
        if offset < 0 or offset + len(value) > fork["size"]:
            raise ValueError("Replacement exceeds the original fork")
        written = 0
        logical = 0
        with self.path.open("r+b") as file:
            for block, count in fork["extents"]:
                capacity = count * self.block_size
                if offset >= logical + capacity:
                    logical += capacity
                    continue
                within = max(0, offset - logical)
                amount = min(capacity - within, len(value) - written)
                file.seek(self.base + block*self.block_size + within)
                file.write(value[written:written+amount])
                written += amount; offset += amount; logical += capacity
                if written == len(value):
                    return
        raise ValueError("Not all data was written")


def patch_image(image_path, layout_path):
    image = HFSImage(image_path)
    background = image.records[(2, BACKGROUND)]
    write_layout(layout_path, background_alias(image.created, background["created"], background["id"]))
    metadata = Path(layout_path).read_bytes()
    fork = image.records[(2, ".DS_Store")]["fork"]
    if len(metadata) != fork["size"]:
        raise ValueError("Finder metadata size changed after image creation")
    image.write_fork_at(fork, 0, metadata)
    # The hybrid-image writer invents legacy Finder coordinates on catalog
    # entries. Signed bundles must not acquire FinderInfo extended attributes.
    # Keep all Finder presentation metadata outside the signed application.
    pending = [image.records[(2, "ControlFlip.app")]]
    while pending:
        entry = pending.pop()
        image.write_fork_at(image.catalog_fork, entry["catalog_offset"] + 48, bytes(32))
        if entry["kind"] == 1:
            pending.extend(record for (parent, _), record in image.records.items() if parent == entry["id"])
    # The root folder uses the image's .VolumeIcon.icns.
    root = image.records[(1, NAME)]
    flags_offset = root["catalog_offset"] + 56
    flags = struct.unpack_from(">H", image.catalog, flags_offset)[0] | 0x0400
    image.write_fork_at(image.catalog_fork, flags_offset, struct.pack(">H", flags))
    # Open the root folder when Finder mounts this installer.
    with Path(image_path).open("r+b") as file:
        file.seek(image.header + 88)
        file.write(struct.pack(">I", 2))
    verify_image(image_path)


def verify_image(path):
    image = HFSImage(path)
    background = image.records[(2, BACKGROUND)]
    metadata = image.read_fork(image.records[(2, ".DS_Store")]["fork"])
    with DSStore.open(io.BytesIO(metadata), "r") as store:
        options = store["."]["icvp"]
        alias = Alias.from_bytes(options["backgroundImageAlias"])
        assert alias.volume.name == NAME
        assert alias.volume.creation_date == MAC_EPOCH + datetime.timedelta(seconds=image.created)
        assert alias.target.cnid == background["id"]
        assert alias.target.folder_cnid == 2
        assert alias.target.posix_path == "/" + BACKGROUND
        assert store["ControlFlip.app"]["Iloc"] == (210, 220)
        assert store["Программы"]["Iloc"] == (550, 220)
        assert store["."]["bwsp"]["ShowToolbar"] is False
        assert options["iconSize"] == 128.0
        assert options["backgroundType"] == 2
    assert image.read_fork(image.records[(2, "Программы")]["fork"]) == b"/Applications"
    visible = {name for parent, name in image.records if parent == 2 and not name.startswith(".")}
    assert visible == {"ControlFlip.app", "Программы"}, visible
    assert struct.unpack_from(">I", image.data, image.header+88)[0] == 2
    assert ".VolumeIcon.icns" in {name for parent, name in image.records if parent == 2}
    app = image.records[(2, "ControlFlip.app")]
    assert image.catalog[app["catalog_offset"]+48:app["catalog_offset"]+80] == bytes(32)
    print("PASS: Finder positions, Retina background alias, Applications link, volume icon and automatic opening")


if __name__ == "__main__":
    action, *args = sys.argv[1:]
    if action == "prepare":
        write_layout(Path(args[0])/".DS_Store", background_alias())
    elif action == "patch":
        patch_image(args[0], args[1])
    elif action == "verify":
        verify_image(args[0])
    else:
        raise ValueError("Unknown action")
