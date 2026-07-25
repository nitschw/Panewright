/// <reference types="@raycast/api">

/* 🚧 🚧 🚧
 * This file is auto-generated from the extension's manifest.
 * Do not modify manually. Instead, update the `package.json` file.
 * 🚧 🚧 🚧 */

/* eslint-disable @typescript-eslint/ban-types */

type ExtensionPreferences = {}

/** Preferences accessible in all the extension's commands */
declare type Preferences = ExtensionPreferences

declare namespace Preferences {
  /** Preferences accessible in the `switch-workspace` command */
  export type SwitchWorkspace = ExtensionPreferences & {}
  /** Preferences accessible in the `move-window` command */
  export type MoveWindow = ExtensionPreferences & {}
  /** Preferences accessible in the `layout` command */
  export type Layout = ExtensionPreferences & {}
  /** Preferences accessible in the `open-settings` command */
  export type OpenSettings = ExtensionPreferences & {}
}

declare namespace Arguments {
  /** Arguments passed to the `switch-workspace` command */
  export type SwitchWorkspace = {}
  /** Arguments passed to the `move-window` command */
  export type MoveWindow = {}
  /** Arguments passed to the `layout` command */
  export type Layout = {}
  /** Arguments passed to the `open-settings` command */
  export type OpenSettings = {
  /** general | keys | layout | appearance | bar */
  "tab": string
}
}

