// ABOUTME: Ambient module declarations for @armada/ui — CSS Modules return Record<string,string>.
// ABOUTME: Mirrors the mockup's src/types.d.ts so verbatim ports type-check unchanged.

declare module "*.module.css" {
  const classes: Record<string, string>;
  export default classes;
}
