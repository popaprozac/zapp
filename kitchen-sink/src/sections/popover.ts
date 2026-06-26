import { Window, WindowEvent, Events } from "@zappdev/runtime";
import type { Section } from "./types";
import { card, onAct, setResult } from "../shell/ui";

// PopoverHandle isn't re-exported from the runtime entry; derive it from the
// createPopover return type rather than touching the runtime.
type PopoverHandle = Awaited<ReturnType<ReturnType<typeof Window.current>["createPopover"]>>;

// Module-scope so the popover is created once and reused across section
// re-renders (navigate away + back). The counter inside survives hide/show.
let pop: PopoverHandle | undefined;

export const popoverSection: Section = {
  id: "popover",
  label: "Popover",
  render(host) {
    host.appendChild(card({
      title: "Popover (web content in NSPopover)",
      intro: "ONE popover, re-anchored on demand — created lazily and reused (the counter inside survives hide/show). Shown here from this button AND from the Compose toolbar item; same popover, two anchors.",
      buttons: [
        { act: "from-button", label: "Popover from this button" },
        { act: "from-toolbar", label: "Popover from Compose item" },
      ],
    }));
    const ensure = async () =>
      (pop ??= await Window.current().createPopover({ url: "#popover-pane", width: 280, height: 180 }));
    onAct(host, "from-button", async () => {
      const btn = host.querySelector<HTMLElement>('[data-act="from-button"]')!;
      (await ensure()).show(btn);
      setResult(host, "shown (anchored to button)");
    });
    onAct(host, "from-toolbar", async () => {
      (await ensure()).show({ toolbarItem: "compose" });
      setResult(host, "shown (anchored to Compose toolbar item)");
    });
    const win = Window.current();
    const off = [
      win.on(WindowEvent.POPOVER_CLOSED, (p: any) => setResult(host, `closed: ${p.popoverId}`)),
      Events.on("ks:popover-emit", () => setResult(host, "popover emitted an event → main pane received it")),
    ];
    return () => off.forEach((fn) => fn());
  },
};
