import {
  ZappError,
  registerBridgeErrorFactory,
  type BridgeErrorPayload,
} from "./errors";

export interface MenuErrorPayload {
  message: string;
}

/** A menu definition or command update was rejected by native Zapp. */
export class MenuError extends ZappError {
  constructor(payload: MenuErrorPayload) {
    super({ code: "MENU_ERROR", message: payload.message });
    this.name = "MenuError";
  }
}

registerBridgeErrorFactory("MENU_ERROR", (payload: BridgeErrorPayload) => (
  new MenuError({ message: payload.message })
));
