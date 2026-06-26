/** Dedicated single-page content for the sheet demos (page / form / drawer),
 *  instead of falling through to the full kitchen-sink shell. */
export function renderSheetPane(app: HTMLElement) {
  const variant = location.hash.split("=")[1] ?? "settings";
  const wrap = (title: string, body: string) =>
    `<div style="padding:24px; font:14px system-ui; box-sizing:border-box;">
       <h2 style="margin:0 0 12px; font-size:18px;">${title}</h2>${body}</div>`;

  if (variant === "quickadd") {
    app.innerHTML = wrap("Quick Add",
      `<input placeholder="Title" style="display:block;width:100%;padding:8px;margin-bottom:10px;box-sizing:border-box;"/>
       <textarea placeholder="Notes" rows="3" style="display:block;width:100%;padding:8px;box-sizing:border-box;"></textarea>
       <button style="margin-top:12px;padding:8px 14px;">Add</button>`);
    return;
  }
  if (variant === "drawer") {
    app.innerHTML = wrap("Drawer",
      `<ul style="margin:0;padding-left:18px;line-height:1.9;">
         <li>Recent file one</li><li>Recent file two</li><li>Recent file three</li></ul>
       <p style="opacity:0.6;margin-top:14px;">A bottom-sheet drawer with system detents (drag the grabber).</p>`);
    return;
  }
  // settings (default)
  app.innerHTML = wrap("Settings",
    `<label style="display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid #8884;">Notifications <input type="checkbox" checked/></label>
     <label style="display:flex;justify-content:space-between;padding:8px 0;border-bottom:1px solid #8884;">Auto-update <input type="checkbox"/></label>
     <label style="display:flex;justify-content:space-between;padding:8px 0;">Theme <select><option>System</option><option>Light</option><option>Dark</option></select></label>`);
}
