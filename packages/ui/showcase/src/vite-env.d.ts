// ABOUTME: Ambient module declarations for the showcase — CSS Modules + bare CSS asset imports.
// ABOUTME: Applies globally within this TS program, so transitively-imported @armada/ui components type-check too.

/// <reference types="vite/client" />

declare module "*.module.css" {
  const classes: Record<string, string>;
  export default classes;
}

declare module "*.css" {
  const css: string;
  export default css;
}
