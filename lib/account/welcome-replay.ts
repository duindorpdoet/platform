// Remember an explicit UI request until the verified guidance record is loaded.
// This carries no identity, permissions or read confirmation.
let pending=false;
export function requestWelcomeReplay(){pending=true;window.dispatchEvent(new Event('poorten-open-welcome'));}
export function consumeWelcomeReplay(){const requested=pending;pending=false;return requested;}
