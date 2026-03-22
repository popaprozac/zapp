const { app, BrowserWindow } = require('electron');
const path = require('path');
app.whenReady().then(() => {
  const win = new BrowserWindow({ width: 600, height: 400 });
  win.loadFile('index.html');
});
app.on('window-all-closed', () => app.quit());
