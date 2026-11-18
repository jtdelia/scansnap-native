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
    return writeExclusiveCopy(as: name, in: destinationDirectory) { output in
        fcopyfile(input, output, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 ? 0 : errno
    }
}

func writeExclusiveCopy(as name: String, in destinationDirectory: Int32, _ copy: (Int32) -> Int32) -> Int32 {
    let output = openat(destinationDirectory, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
    guard output >= 0 else { return errno }

    let code = copy(output)
    if close(output) != 0, code == 0 { return errno }
    return code
}
