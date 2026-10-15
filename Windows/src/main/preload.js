// The bridge between the interface and the main process.
const { contextBridge, ipcRenderer, webUtils } = require('electron')
const { pathToFileURL } = require('url')

const invoke = (ch, ...a) => ipcRenderer.invoke(ch, ...a)
const on = (ch, fn) => {
  const h = (_e, data) => fn(data)
  ipcRenderer.on(ch, h)
  return () => ipcRenderer.removeListener(ch, h)
}

contextBridge.exposeInMainWorld('api', {
  invoke,
  on,
  fileURL: p => pathToFileURL(p).href,
  /** Path of a file dropped onto the window. */
  pathFor: file => webUtils.getPathForFile(file),
  platform: process.platform,
})
