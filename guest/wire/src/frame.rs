//! Length-prefixed JSON frame codec: a 4-byte big-endian length, then that
//! many bytes of payload. The bound is checked before any allocation.

use std::io::{self, Read, Write};

pub const MAX_FRAME: usize = 4 * 1024 * 1024;

pub fn read_frame<R: Read>(reader: &mut R) -> io::Result<Vec<u8>> {
    let mut len_buf = [0u8; 4];
    reader.read_exact(&mut len_buf)?;
    let len = u32::from_be_bytes(len_buf) as usize;
    if len > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame exceeds 4 MiB bound",
        ));
    }
    let mut payload = Vec::new();
    payload
        .try_reserve_exact(len)
        .map_err(|_| io::Error::new(io::ErrorKind::OutOfMemory, "frame allocation failed"))?;
    payload.resize(len, 0);
    reader.read_exact(&mut payload)?;
    debug_assert_eq!(payload.len(), len);
    Ok(payload)
}

pub fn write_frame<W: Write>(writer: &mut W, payload: &[u8]) -> io::Result<()> {
    let len = payload.len();
    if len > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "frame exceeds 4 MiB bound",
        ));
    }
    let len_u32 = u32::try_from(len)
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidData, "length overflow"))?;
    writer.write_all(&len_u32.to_be_bytes())?;
    writer.write_all(payload)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::{MAX_FRAME, read_frame, write_frame};
    use std::io::Cursor;

    #[test]
    fn round_trip_preserves_payload() {
        let payload = br#"{"id":1,"op":"ping"}"#;
        let mut buf = Vec::new();
        write_frame(&mut buf, payload).expect("write");
        let mut cursor = Cursor::new(buf);
        let got = read_frame(&mut cursor).expect("read");
        assert_eq!(got, payload);
    }

    #[test]
    fn read_rejects_oversize_without_allocating() {
        let bogus = u32::try_from(MAX_FRAME).expect("fits u32") + 1;
        let mut buf = Vec::new();
        buf.extend_from_slice(&bogus.to_be_bytes());
        let mut cursor = Cursor::new(buf);
        let err = read_frame(&mut cursor).expect_err("must reject oversize");
        assert_eq!(err.kind(), std::io::ErrorKind::InvalidData);
    }

    #[test]
    fn write_rejects_oversize() {
        let payload = vec![0u8; MAX_FRAME + 1];
        let mut buf = Vec::new();
        let err = write_frame(&mut buf, &payload).expect_err("must reject oversize");
        assert_eq!(err.kind(), std::io::ErrorKind::InvalidData);
        assert!(buf.is_empty());
    }

    #[test]
    fn round_trip_empty_payload() {
        let mut buf = Vec::new();
        write_frame(&mut buf, b"").expect("write");
        let mut cursor = Cursor::new(buf);
        let got = read_frame(&mut cursor).expect("read");
        assert!(got.is_empty());
    }
}
