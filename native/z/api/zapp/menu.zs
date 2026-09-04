import {
  Command as FrameworkCommand,
  CommandAction as FrameworkCommandAction,
  CommandInvocation as FrameworkCommandInvocation,
  CommandOptions as FrameworkCommandOptions,
  CommandState as FrameworkCommandState,
  Menu as FrameworkMenu,
  MenuError as FrameworkMenuError,
  MenuGroup as FrameworkMenuGroup,
  MenuItem as FrameworkMenuItem,
  MenuRole as FrameworkMenuRole,
} from "../../framework/menu.zs";
import { thread } from "std/thread";

export type Command = FrameworkCommand;
export type CommandAction = FrameworkCommandAction;
export type CommandInvocation = FrameworkCommandInvocation;
export type CommandOptions = FrameworkCommandOptions;
export type CommandState = FrameworkCommandState;
export type Menu = FrameworkMenu;
export type MenuError = FrameworkMenuError;
export type MenuGroup = FrameworkMenuGroup;
export type MenuItem = FrameworkMenuItem;
export type MenuRole = FrameworkMenuRole;
