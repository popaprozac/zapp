import { Window, WindowEvent } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";
import { paneState } from "../shell/pane-state";

export const sidebarSection: Section = {
  id: "sidebar",
  label: "Sidebar",
  render(host) {
    const win = Window.current();
    const pane = paneState.get(win.id).sidebar;
    host.appendChild(
      card({
        title: "Native Sidebar",
        intro:
          "A real NSSplitViewItem sidebar (this window's left nav). Toggling hides the nav; the toolbar's sidebar button brings it back. Collapse/resize gating controls whether the user can collapse it or drag the divider (set at create time too, via sidebar.collapsible / sidebar.resizable).",
        buttons: [
          { act: "toggle", label: "Toggle" },
          { act: "w180", label: "Width 180" },
          { act: "w320", label: "Width 320" },
          {
            act: "collapsible",
            label: `Collapsible: ${pane.collapsible ? "on" : "off"}`,
          },
          {
            act: "resizable",
            label: `Resizable: ${pane.resizable ? "on" : "off"}`,
          },
          { act: "presAuto", label: "Auto" },
          { act: "presTile", label: "Tile" },
          { act: "presOverlay", label: "Overlay" },
          { act: "titleFiles", label: 'Rename → "Files"' },
          { act: "titleKitchenSink", label: 'Rename → "Kitchen Sink"' },
        ],
        note: "<b>On iPad:</b> the sidebar tiles beside the content (Mail-style); at narrow widths or in Slide Over it becomes an overlay — switch <b>Auto / Tile / Overlay</b> to compare. With <b>Resizable: on</b> the user owns the width: drag the divider to resize. <code>setWidth</code> (the Width buttons) sets the starting width, but once you drag, your width wins and <code>setWidth</code> stops moving the divider — a UIKit limitation. Switch <b>Resizable: off</b> to make <code>setWidth</code> authoritative again. <b>On iPhone:</b> the sidebar is a slide-over drawer. (On macOS it's the native NSSplitView above — drag and <code>setWidth</code> always cooperate.) The <b>Rename</b> buttons test the live per-pane sidebar title (iOS/iPadOS; macOS is a documented no-op).",
      }),
    );
    onAct(host, "toggle", () => {
      win.sidebar?.toggle();
      setResult(host, "toggled");
    });
    onAct(host, "w180", () => {
      win.sidebar?.setWidth(180);
      setResult(host, "width → 180");
    });
    onAct(host, "w320", () => {
      win.sidebar?.setWidth(320);
      setResult(host, "width → 320");
    });
    onAct(host, "collapsible", () => {
      pane.collapsible = !pane.collapsible;
      win.sidebar?.setCollapsible(pane.collapsible);
      const btn = host.querySelector<HTMLButtonElement>(
        '[data-act="collapsible"]',
      );
      if (btn)
        btn.textContent = `Collapsible: ${pane.collapsible ? "on" : "off"}`;
      setResult(host, `collapsible → ${pane.collapsible}`);
    });
    onAct(host, "resizable", () => {
      pane.resizable = !pane.resizable;
      win.sidebar?.setResizable(pane.resizable);
      const btn = host.querySelector<HTMLButtonElement>(
        '[data-act="resizable"]',
      );
      if (btn)
        btn.textContent = `Resizable: ${pane.resizable ? "on" : "off"}`;
      setResult(
        host,
        `resizable → ${pane.resizable} (try dragging the divider)`,
      );
    });
    onAct(host, "presAuto", () => {
      win.sidebar?.setPresentation("automatic");
      setResult(host, "presentation → automatic");
    });
    onAct(host, "presTile", () => {
      win.sidebar?.setPresentation("tile");
      setResult(host, "presentation → tile");
    });
    onAct(host, "presOverlay", () => {
      win.sidebar?.setPresentation("overlay");
      setResult(host, "presentation → overlay");
    });
    onAct(host, "titleFiles", () => {
      win.sidebar?.setTitle("Files");
      setResult(host, 'title → "Files"');
    });
    onAct(host, "titleKitchenSink", () => {
      win.sidebar?.setTitle("Kitchen Sink");
      setResult(host, 'title → "Kitchen Sink"');
    });
  },
  inspector(host) {
    const win = Window.current();
    host.innerHTML = `<div class="kv"><b>Sidebar</b><div data-state class="muted">Live — collapse, expand, or drag the sidebar to see state.</div></div>`;
    const state = host.querySelector<HTMLElement>("[data-state]")!;
    const subscriptions = [
      win.subscribe(WindowEvent.SIDEBAR_COLLAPSED, () => {
        state.textContent = "collapsed";
      }),
      win.subscribe(WindowEvent.SIDEBAR_EXPANDED, () => {
        state.textContent = "expanded";
      }),
      win.subscribe(WindowEvent.SIDEBAR_RESIZED, (d: any) => {
        state.textContent = `width ${d.width}`;
      }),
    ];
    return () => subscriptions.forEach((subscription) => subscription.unsubscribe());
  },
};
