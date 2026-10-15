// electron-builder can only stamp the .exe's icon and version on Windows (it needs rcedit), so it's done here
// in plain JavaScript with resedit, which works when building on a Mac.
const fs = require('fs'), path = require('path')
exports.default = async function (ctx) {
  if (ctx.electronPlatformName !== 'win32') return
  const ResEdit = await import('resedit')
  const { NtExecutable, NtExecutableResource, Resource, Data } = ResEdit.default || ResEdit
  const name = ctx.packager.appInfo.productFilename
  const exePath = path.join(ctx.appOutDir, `${name}.exe`)
  const exe = NtExecutable.from(fs.readFileSync(exePath), { ignoreCert: true })
  const res = NtExecutableResource.from(exe)
  const ico = Data.IconFile.from(fs.readFileSync(path.join(__dirname, 'icon.ico')))
  Resource.IconGroupEntry.replaceIconsForResource(res.entries, 1, 1033, ico.icons.map(i => i.data))
  const version = ctx.packager.appInfo.version
  const [vi] = Resource.VersionInfo.fromEntries(res.entries)
  const parts = version.split('.').map(Number)
  vi.setFileVersion(parts[0], parts[1], parts[2], 0, 1033)
  vi.setProductVersion(parts[0], parts[1], parts[2], 0, 1033)
  vi.setStringValues({ lang: 1033, codepage: 1200 }, {
    FileDescription: 'MP3 Tagger', ProductName: 'MP3 Tagger', OriginalFilename: `${name}.exe`,
    InternalName: 'MP3 Tagger', CompanyName: 'MP3 Tagger', LegalCopyright: '',
    FileVersion: version, ProductVersion: version,
  })
  vi.outputToResourceEntries(res.entries)
  res.outputResource(exe)
  fs.writeFileSync(exePath, Buffer.from(exe.generate()))
  console.log('  • stamped icon and version into', path.basename(exePath))
}
