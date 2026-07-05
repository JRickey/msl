//! `FSKit` file-service protocol v1: the compact binary request/reply codec.
//!
//! Shared by the host appex (Swift `MSLCore/FSProto.swift`) and the guest
//! `msl-fsd` worker. All integers are little-endian; strings are `u16`-length-
//! prefixed UTF-8; read data is a `u32`-length-prefixed blob. See
//! `docs/specs/fskit-file-protocol.md`. Golden vectors keep both sides
//! identical.

use std::string::FromUtf8Error;

/// Wire version negotiated once in the guest hello, not per message.
pub const FS_PROTOCOL_VERSION: u32 = 1;
/// Single `read` reply data cap in v1 (the frame cap stays 4 MiB).
pub const MAX_READ_REPLY: usize = 1 << 20;
/// Maximum encodable string byte length (u16 prefix).
pub const MAX_STRING: usize = u16::MAX as usize;

/// Encode failures: a string or blob exceeds its length prefix.
#[derive(Debug, PartialEq, Eq)]
pub enum EncodeError {
    StringTooLong(usize),
    BlobTooLong(usize),
}

/// Decode failures: truncated input, invalid tag, bad UTF-8, or trailing bytes.
#[derive(Debug, PartialEq, Eq)]
pub enum DecodeError {
    Truncated,
    BadOp(u8),
    BadItemType(u8),
    BadUtf8,
    TrailingBytes,
    OversizeBlob(usize),
}

impl From<FromUtf8Error> for DecodeError {
    fn from(_: FromUtf8Error) -> Self {
        Self::BadUtf8
    }
}

/// Little-endian byte writer over a growable buffer.
struct Writer {
    buf: Vec<u8>,
}

impl Writer {
    const fn new() -> Self {
        Self { buf: Vec::new() }
    }
    fn u8(&mut self, value: u8) {
        self.buf.push(value);
    }
    fn u16(&mut self, value: u16) {
        self.buf.extend_from_slice(&value.to_le_bytes());
    }
    fn u32(&mut self, value: u32) {
        self.buf.extend_from_slice(&value.to_le_bytes());
    }
    fn u64(&mut self, value: u64) {
        self.buf.extend_from_slice(&value.to_le_bytes());
    }
    fn i32(&mut self, value: i32) {
        self.buf.extend_from_slice(&value.to_le_bytes());
    }
    fn i64(&mut self, value: i64) {
        self.buf.extend_from_slice(&value.to_le_bytes());
    }
    fn string(&mut self, value: &str) -> Result<(), EncodeError> {
        let len = value.len();
        if len > MAX_STRING {
            return Err(EncodeError::StringTooLong(len));
        }
        let short = u16::try_from(len).map_err(|_| EncodeError::StringTooLong(len))?;
        self.u16(short);
        self.buf.extend_from_slice(value.as_bytes());
        Ok(())
    }
    fn blob(&mut self, value: &[u8]) -> Result<(), EncodeError> {
        let len = value.len();
        let wide = u32::try_from(len).map_err(|_| EncodeError::BlobTooLong(len))?;
        self.u32(wide);
        self.buf.extend_from_slice(value);
        Ok(())
    }
}

/// Little-endian byte reader with bounds checks and a final trailing-byte check.
struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    const fn new(buf: &'a [u8]) -> Self {
        Self { buf, pos: 0 }
    }
    fn take(&mut self, count: usize) -> Result<&'a [u8], DecodeError> {
        let end = self.pos.checked_add(count).ok_or(DecodeError::Truncated)?;
        if end > self.buf.len() {
            return Err(DecodeError::Truncated);
        }
        let slice = &self.buf[self.pos..end];
        self.pos = end;
        Ok(slice)
    }
    fn u8(&mut self) -> Result<u8, DecodeError> {
        Ok(self.take(1)?[0])
    }
    fn u16(&mut self) -> Result<u16, DecodeError> {
        let bytes: [u8; 2] = self
            .take(2)?
            .try_into()
            .map_err(|_| DecodeError::Truncated)?;
        Ok(u16::from_le_bytes(bytes))
    }
    fn u32(&mut self) -> Result<u32, DecodeError> {
        let bytes: [u8; 4] = self
            .take(4)?
            .try_into()
            .map_err(|_| DecodeError::Truncated)?;
        Ok(u32::from_le_bytes(bytes))
    }
    fn u64(&mut self) -> Result<u64, DecodeError> {
        let bytes: [u8; 8] = self
            .take(8)?
            .try_into()
            .map_err(|_| DecodeError::Truncated)?;
        Ok(u64::from_le_bytes(bytes))
    }
    fn i32(&mut self) -> Result<i32, DecodeError> {
        let bytes: [u8; 4] = self
            .take(4)?
            .try_into()
            .map_err(|_| DecodeError::Truncated)?;
        Ok(i32::from_le_bytes(bytes))
    }
    fn i64(&mut self) -> Result<i64, DecodeError> {
        let bytes: [u8; 8] = self
            .take(8)?
            .try_into()
            .map_err(|_| DecodeError::Truncated)?;
        Ok(i64::from_le_bytes(bytes))
    }
    fn string(&mut self) -> Result<String, DecodeError> {
        let len = self.u16()? as usize;
        let bytes = self.take(len)?;
        Ok(String::from_utf8(bytes.to_vec())?)
    }
    fn blob(&mut self) -> Result<Vec<u8>, DecodeError> {
        let len = self.u32()? as usize;
        if len > MAX_READ_REPLY {
            return Err(DecodeError::OversizeBlob(len));
        }
        Ok(self.take(len)?.to_vec())
    }
    const fn finish(self) -> Result<(), DecodeError> {
        if self.pos == self.buf.len() {
            Ok(())
        } else {
            Err(DecodeError::TrailingBytes)
        }
    }
}

/// Linux item type mapped to `FSItem.ItemType` on the host.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ItemType {
    Unknown,
    File,
    Dir,
    Symlink,
    Fifo,
    Char,
    Block,
    Socket,
}

impl ItemType {
    #[must_use]
    pub const fn to_u8(self) -> u8 {
        match self {
            Self::Unknown => 0,
            Self::File => 1,
            Self::Dir => 2,
            Self::Symlink => 3,
            Self::Fifo => 4,
            Self::Char => 5,
            Self::Block => 6,
            Self::Socket => 7,
        }
    }
    pub const fn from_u8(value: u8) -> Result<Self, DecodeError> {
        match value {
            0 => Ok(Self::Unknown),
            1 => Ok(Self::File),
            2 => Ok(Self::Dir),
            3 => Ok(Self::Symlink),
            4 => Ok(Self::Fifo),
            5 => Ok(Self::Char),
            6 => Ok(Self::Block),
            7 => Ok(Self::Socket),
            other => Err(DecodeError::BadItemType(other)),
        }
    }
}

/// A timestamp with nanosecond precision.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Timespec {
    pub sec: i64,
    pub nsec: u32,
}

/// File attributes returned by lookup / getattr / readdirplus.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Attr {
    pub node_id: u64,
    pub file_id: u64,
    pub parent_id: u64,
    pub item_type: ItemType,
    pub mode: u32,
    pub uid: u32,
    pub gid: u32,
    pub nlink: u32,
    pub size: u64,
    pub alloc_size: u64,
    pub atime: Timespec,
    pub mtime: Timespec,
    pub ctime: Timespec,
    pub flags: u32,
}

impl Attr {
    fn write(&self, writer: &mut Writer) {
        writer.u64(self.node_id);
        writer.u64(self.file_id);
        writer.u64(self.parent_id);
        writer.u8(self.item_type.to_u8());
        writer.u32(self.mode);
        writer.u32(self.uid);
        writer.u32(self.gid);
        writer.u32(self.nlink);
        writer.u64(self.size);
        writer.u64(self.alloc_size);
        Self::write_time(writer, self.atime);
        Self::write_time(writer, self.mtime);
        Self::write_time(writer, self.ctime);
        writer.u32(self.flags);
    }
    fn write_time(writer: &mut Writer, time: Timespec) {
        writer.i64(time.sec);
        writer.u32(time.nsec);
    }
    fn read(reader: &mut Reader) -> Result<Self, DecodeError> {
        let node_id = reader.u64()?;
        let file_id = reader.u64()?;
        let parent_id = reader.u64()?;
        let item_type = ItemType::from_u8(reader.u8()?)?;
        let (mode, uid, gid, nlink) = (reader.u32()?, reader.u32()?, reader.u32()?, reader.u32()?);
        let size = reader.u64()?;
        let alloc_size = reader.u64()?;
        let atime = Self::read_time(reader)?;
        let mtime = Self::read_time(reader)?;
        let ctime = Self::read_time(reader)?;
        let flags = reader.u32()?;
        Ok(Self {
            node_id,
            file_id,
            parent_id,
            item_type,
            mode,
            uid,
            gid,
            nlink,
            size,
            alloc_size,
            atime,
            mtime,
            ctime,
            flags,
        })
    }
    fn read_time(reader: &mut Reader) -> Result<Timespec, DecodeError> {
        Ok(Timespec {
            sec: reader.i64()?,
            nsec: reader.u32()?,
        })
    }
}

/// Filesystem statistics.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Statfs {
    pub blocks: u64,
    pub bfree: u64,
    pub bavail: u64,
    pub files: u64,
    pub ffree: u64,
    pub bsize: u32,
    pub namemax: u32,
}

impl Statfs {
    fn write(&self, writer: &mut Writer) {
        writer.u64(self.blocks);
        writer.u64(self.bfree);
        writer.u64(self.bavail);
        writer.u64(self.files);
        writer.u64(self.ffree);
        writer.u32(self.bsize);
        writer.u32(self.namemax);
    }
    fn read(reader: &mut Reader) -> Result<Self, DecodeError> {
        Ok(Self {
            blocks: reader.u64()?,
            bfree: reader.u64()?,
            bavail: reader.u64()?,
            files: reader.u64()?,
            ffree: reader.u64()?,
            bsize: reader.u32()?,
            namemax: reader.u32()?,
        })
    }
}

/// One readdirplus entry: name plus full attributes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DirEntry {
    pub name: String,
    pub attr: Attr,
}

/// A file-service request.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Request {
    Statfs,
    Lookup {
        parent: u64,
        name: String,
    },
    Getattr {
        node: u64,
        wanted: u32,
    },
    Readdirplus {
        node: u64,
        cookie: u64,
        max_entries: u32,
        wanted: u32,
    },
    Open {
        node: u64,
        mode: u8,
    },
    Read {
        handle: u64,
        offset: u64,
        length: u32,
    },
    CloseFile {
        handle: u64,
    },
    Readlink {
        node: u64,
    },
    Reclaim {
        node: u64,
    },
    Sync,
    Close,
}

impl Request {
    #[must_use]
    pub const fn op(&self) -> u8 {
        match self {
            Self::Statfs => 1,
            Self::Lookup { .. } => 2,
            Self::Getattr { .. } => 3,
            Self::Readdirplus { .. } => 4,
            Self::Open { .. } => 5,
            Self::Read { .. } => 6,
            Self::CloseFile { .. } => 7,
            Self::Readlink { .. } => 8,
            Self::Reclaim { .. } => 9,
            Self::Sync => 10,
            Self::Close => 11,
        }
    }
}

/// A request with its id, ready to frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RequestFrame {
    pub id: u64,
    pub request: Request,
}

impl RequestFrame {
    pub fn encode(&self) -> Result<Vec<u8>, EncodeError> {
        let mut writer = Writer::new();
        writer.u8(self.request.op());
        writer.u64(self.id);
        self.write_args(&mut writer)?;
        Ok(writer.buf)
    }

    fn write_args(&self, writer: &mut Writer) -> Result<(), EncodeError> {
        match &self.request {
            Request::Statfs | Request::Sync | Request::Close => {}
            Request::Lookup { parent, name } => {
                writer.u64(*parent);
                writer.string(name)?;
            }
            Request::Getattr { node, wanted } => {
                writer.u64(*node);
                writer.u32(*wanted);
            }
            Request::Readdirplus {
                node,
                cookie,
                max_entries,
                wanted,
            } => {
                writer.u64(*node);
                writer.u64(*cookie);
                writer.u32(*max_entries);
                writer.u32(*wanted);
            }
            Request::Open { node, mode } => {
                writer.u64(*node);
                writer.u8(*mode);
            }
            Request::Read {
                handle,
                offset,
                length,
            } => {
                writer.u64(*handle);
                writer.u64(*offset);
                writer.u32(*length);
            }
            Request::CloseFile { handle } => writer.u64(*handle),
            Request::Readlink { node } | Request::Reclaim { node } => writer.u64(*node),
        }
        Ok(())
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut reader = Reader::new(bytes);
        let op = reader.u8()?;
        let id = reader.u64()?;
        let request = Self::read_request(op, &mut reader)?;
        reader.finish()?;
        Ok(Self { id, request })
    }

    fn read_request(op: u8, reader: &mut Reader) -> Result<Request, DecodeError> {
        match op {
            1 => Ok(Request::Statfs),
            2 => Ok(Request::Lookup {
                parent: reader.u64()?,
                name: reader.string()?,
            }),
            3 => Ok(Request::Getattr {
                node: reader.u64()?,
                wanted: reader.u32()?,
            }),
            4 => Ok(Request::Readdirplus {
                node: reader.u64()?,
                cookie: reader.u64()?,
                max_entries: reader.u32()?,
                wanted: reader.u32()?,
            }),
            5 => Ok(Request::Open {
                node: reader.u64()?,
                mode: reader.u8()?,
            }),
            6 => Ok(Request::Read {
                handle: reader.u64()?,
                offset: reader.u64()?,
                length: reader.u32()?,
            }),
            7 => Ok(Request::CloseFile {
                handle: reader.u64()?,
            }),
            8 => Ok(Request::Readlink {
                node: reader.u64()?,
            }),
            9 => Ok(Request::Reclaim {
                node: reader.u64()?,
            }),
            10 => Ok(Request::Sync),
            11 => Ok(Request::Close),
            other => Err(DecodeError::BadOp(other)),
        }
    }
}

/// A successful reply body, tagged by the request op it answers.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ReplyBody {
    Statfs(Statfs),
    Attr(Attr),
    Readdirplus {
        eof: bool,
        next_cookie: u64,
        entries: Vec<DirEntry>,
    },
    Open {
        handle: u64,
    },
    Read {
        data: Vec<u8>,
        eof: bool,
    },
    Readlink {
        target: String,
    },
    Empty,
}

/// A POSIX error reply.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FsError {
    pub errno: i32,
    pub message: String,
}

/// A reply with its echoed id and op, carrying either a body or an error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ReplyFrame {
    pub id: u64,
    pub op: u8,
    pub result: Result<ReplyBody, FsError>,
}

impl ReplyFrame {
    pub const fn ok(id: u64, op: u8, body: ReplyBody) -> Self {
        Self {
            id,
            op,
            result: Ok(body),
        }
    }
    pub const fn err(id: u64, op: u8, errno: i32, message: String) -> Self {
        Self {
            id,
            op,
            result: Err(FsError { errno, message }),
        }
    }

    pub fn encode(&self) -> Result<Vec<u8>, EncodeError> {
        let mut writer = Writer::new();
        writer.u64(self.id);
        writer.u8(self.op);
        match &self.result {
            Ok(body) => {
                writer.i32(0);
                Self::write_body(body, &mut writer)?;
            }
            Err(error) => {
                writer.i32(error.errno);
                writer.string(&error.message)?;
            }
        }
        Ok(writer.buf)
    }

    fn write_body(body: &ReplyBody, writer: &mut Writer) -> Result<(), EncodeError> {
        match body {
            ReplyBody::Statfs(statfs) => statfs.write(writer),
            ReplyBody::Attr(attr) => attr.write(writer),
            ReplyBody::Readdirplus {
                eof,
                next_cookie,
                entries,
            } => {
                writer.u8(u8::from(*eof));
                writer.u64(*next_cookie);
                let count = u32::try_from(entries.len())
                    .map_err(|_| EncodeError::BlobTooLong(entries.len()))?;
                writer.u32(count);
                for entry in entries {
                    writer.string(&entry.name)?;
                    entry.attr.write(writer);
                }
            }
            ReplyBody::Open { handle } => writer.u64(*handle),
            ReplyBody::Read { data, eof } => {
                writer.blob(data)?;
                writer.u8(u8::from(*eof));
            }
            ReplyBody::Readlink { target } => writer.string(target)?,
            ReplyBody::Empty => {}
        }
        Ok(())
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut reader = Reader::new(bytes);
        let id = reader.u64()?;
        let op = reader.u8()?;
        let errno = reader.i32()?;
        let result = if errno == 0 {
            Ok(Self::read_body(op, &mut reader)?)
        } else {
            Err(FsError {
                errno,
                message: reader.string()?,
            })
        };
        reader.finish()?;
        Ok(Self { id, op, result })
    }

    fn read_body(op: u8, reader: &mut Reader) -> Result<ReplyBody, DecodeError> {
        match op {
            1 => Ok(ReplyBody::Statfs(Statfs::read(reader)?)),
            2 | 3 => Ok(ReplyBody::Attr(Attr::read(reader)?)),
            4 => Self::read_readdirplus(reader),
            5 => Ok(ReplyBody::Open {
                handle: reader.u64()?,
            }),
            6 => Ok(ReplyBody::Read {
                data: reader.blob()?,
                eof: reader.u8()? != 0,
            }),
            8 => Ok(ReplyBody::Readlink {
                target: reader.string()?,
            }),
            7 | 9 | 10 | 11 => Ok(ReplyBody::Empty),
            other => Err(DecodeError::BadOp(other)),
        }
    }

    fn read_readdirplus(reader: &mut Reader) -> Result<ReplyBody, DecodeError> {
        let eof = reader.u8()? != 0;
        let next_cookie = reader.u64()?;
        let count = reader.u32()? as usize;
        let mut entries = Vec::new();
        entries
            .try_reserve(count.min(4096))
            .map_err(|_| DecodeError::OversizeBlob(count))?;
        for _ in 0..count {
            let name = reader.string()?;
            let attr = Attr::read(reader)?;
            entries.push(DirEntry { name, attr });
        }
        Ok(ReplyBody::Readdirplus {
            eof,
            next_cookie,
            entries,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample_attr() -> Attr {
        Attr {
            node_id: 5,
            file_id: 4242,
            parent_id: 1,
            item_type: ItemType::File,
            mode: 0o100_644,
            uid: 1000,
            gid: 1000,
            nlink: 1,
            size: 12345,
            alloc_size: 16384,
            atime: Timespec {
                sec: 1_700_000_000,
                nsec: 111,
            },
            mtime: Timespec {
                sec: 1_700_000_001,
                nsec: 222,
            },
            ctime: Timespec {
                sec: 1_700_000_002,
                nsec: 333,
            },
            flags: 0,
        }
    }

    #[test]
    fn request_round_trip_all_ops() {
        let requests = [
            Request::Statfs,
            Request::Lookup {
                parent: 1,
                name: "etc".into(),
            },
            Request::Getattr { node: 5, wanted: 0 },
            Request::Readdirplus {
                node: 1,
                cookie: 0,
                max_entries: 128,
                wanted: 0,
            },
            Request::Open { node: 5, mode: 0 },
            Request::Read {
                handle: 9,
                offset: 4096,
                length: 65536,
            },
            Request::CloseFile { handle: 9 },
            Request::Readlink { node: 7 },
            Request::Reclaim { node: 5 },
            Request::Sync,
            Request::Close,
        ];
        for (index, request) in requests.into_iter().enumerate() {
            let frame = RequestFrame {
                id: index as u64 + 1,
                request,
            };
            let bytes = frame.encode().expect("encode");
            assert_eq!(RequestFrame::decode(&bytes).expect("decode"), frame);
        }
    }

    #[test]
    fn reply_round_trip_bodies() {
        let bodies = [
            (
                1u8,
                ReplyBody::Statfs(Statfs {
                    blocks: 1000,
                    bfree: 500,
                    bavail: 400,
                    files: 200,
                    ffree: 100,
                    bsize: 4096,
                    namemax: 255,
                }),
            ),
            (3u8, ReplyBody::Attr(sample_attr())),
            (
                4u8,
                ReplyBody::Readdirplus {
                    eof: true,
                    next_cookie: 0,
                    entries: vec![DirEntry {
                        name: "os-release".into(),
                        attr: sample_attr(),
                    }],
                },
            ),
            (5u8, ReplyBody::Open { handle: 42 }),
            (
                6u8,
                ReplyBody::Read {
                    data: vec![1, 2, 3, 4],
                    eof: false,
                },
            ),
            (
                8u8,
                ReplyBody::Readlink {
                    target: "/usr/lib".into(),
                },
            ),
            (7u8, ReplyBody::Empty),
        ];
        for (op, body) in bodies {
            let frame = ReplyFrame::ok(7, op, body);
            let bytes = frame.encode().expect("encode");
            assert_eq!(ReplyFrame::decode(&bytes).expect("decode"), frame);
        }
    }

    #[test]
    fn reply_errno_round_trip() {
        let frame = ReplyFrame::err(3, 2, libc::ENOENT, "no such file".into());
        let bytes = frame.encode().expect("encode");
        let decoded = ReplyFrame::decode(&bytes).expect("decode");
        assert_eq!(decoded, frame);
        match decoded.result {
            Err(error) => assert_eq!(error.errno, libc::ENOENT),
            Ok(_) => panic!("expected error"),
        }
    }

    #[test]
    fn decode_rejects_trailing_bytes() {
        let mut bytes = RequestFrame {
            id: 1,
            request: Request::Statfs,
        }
        .encode()
        .unwrap();
        bytes.push(0xff);
        assert_eq!(
            RequestFrame::decode(&bytes),
            Err(DecodeError::TrailingBytes)
        );
    }

    #[test]
    fn decode_rejects_truncated() {
        let bytes = RequestFrame {
            id: 1,
            request: Request::Lookup {
                parent: 1,
                name: "etc".into(),
            },
        }
        .encode()
        .unwrap();
        assert_eq!(
            RequestFrame::decode(&bytes[..bytes.len() - 2]),
            Err(DecodeError::Truncated)
        );
    }

    #[test]
    fn decode_rejects_bad_op() {
        let bytes = [99u8, 0, 0, 0, 0, 0, 0, 0, 0];
        assert_eq!(RequestFrame::decode(&bytes), Err(DecodeError::BadOp(99)));
    }

    #[test]
    fn read_blob_rejects_oversize() {
        let mut writer = Writer::new();
        writer.u64(1);
        writer.u8(6);
        writer.i32(0);
        writer.u32(u32::try_from(MAX_READ_REPLY + 1).unwrap());
        assert_eq!(
            ReplyFrame::decode(&writer.buf),
            Err(DecodeError::OversizeBlob(MAX_READ_REPLY + 1))
        );
    }

    // Golden vector shared byte-for-byte with the Swift FSProtoTests suite. A
    // getattr reply (id 7, op 3, errno 0) carrying `sample_attr()`.
    #[test]
    fn getattr_reply_golden_vector() {
        use std::fmt::Write as _;
        let frame = ReplyFrame::ok(7, 3, ReplyBody::Attr(sample_attr()));
        let bytes = frame.encode().expect("encode");
        let mut hex = String::new();
        for byte in &bytes {
            write!(hex, "{byte:02x}").expect("write hex");
        }
        assert_eq!(hex, GETATTR_GOLDEN_HEX);
    }

    const GETATTR_GOLDEN_HEX: &str = concat!(
        "0700000000000000030000000005000000000000009210000000000000",
        "010000000000000001a4810000e8030000e803000001000000393000000",
        "0000000004000000000000000f15365000000006f00000001f153650000",
        "0000de00000002f15365000000004d01000000000000",
    );
}
