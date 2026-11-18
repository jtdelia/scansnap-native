import Darwin

func publishFile(_ source: String, from sourceDirectory: Int32, as name: String, in destinationDirectory: Int32) -> Int32 {
    if renameatx_np(sourceDirectory, source, destinationDirectory, name, UInt32(RENAME_EXCL)) == 0 { return 0 }
    guard errno == ENOTSUP else { return errno }
    if linkat(sourceDirectory, source, destinationDirectory, name, 0) != 0 {
        guard errno == ENOTSUP else { return errno }
        let code = copyFileExclusively(source, in: sourceDirectory, as: name, in: destinationDirectory)
        guard code == 0 else { return code }
    }
    unlinkat(sourceDirectory, source, 0)
    return 0
}

private func copyFileExclusively(_ source: String, in sourceDirectory: Int32,
                                 as name: String, in destinationDirectory: Int32) -> Int32 {
    if clonefileat(sourceDirectory, source, destinationDirectory, name, UInt32(CLONE_NOFOLLOW)) == 0 { return 0 }
    guard errno == ENOTSUP else { return errno }
    let input = openat(sourceDirectory, source, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard input >= 0 else { return errno }
    defer { close(input) }
    let output = openat(destinationDirectory, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard output >= 0 else { return errno }

    var code = fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 ? 0 : errno
    var created = stat()
    let identified = fstat(output, &created) == 0
    if close(output) != 0, code == 0 { code = errno }
    if code != 0, identified {
        var entry = stat()
        if fstatat(destinationDirectory, name, &entry, AT_SYMLINK_NOFOLLOW) == 0,
           entry.st_dev == created.st_dev, entry.st_ino == created.st_ino {
            unlinkat(destinationDirectory, name, 0)
        }
    }
    return code
}
