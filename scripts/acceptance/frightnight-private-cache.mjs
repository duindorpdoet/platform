// Deployment headers may add max-age=0 to a route's private, no-store policy.
// Require both privacy directives and accept only compatible non-fresh policies.
export function hasPrivateNoStore(cacheControl) {
  if (typeof cacheControl !== 'string' || !cacheControl || cacheControl.length > 2048 || /[\r\n]/.test(cacheControl)) return false;
  const directives = new Set();
  for (const part of cacheControl.split(',')) {
    const match = /^([a-z-]+)(?:\s*=\s*(0+|"0+"))?$/i.exec(part.trim());
    if (!match) return false;
    const name = match[1].toLowerCase();
    if (directives.has(name)) return false;
    directives.add(name);
    if (name === 'max-age') {
      if (match[2] === undefined) return false;
    } else if (match[2] !== undefined || !['private', 'no-store', 'no-cache', 'must-revalidate', 'proxy-revalidate', 'no-transform'].includes(name)) {
      return false;
    }
  }
  return directives.has('private') && directives.has('no-store');
}
