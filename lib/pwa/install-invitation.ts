export function localDateKey(date = new Date()) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, "0");
  const day = String(date.getDate()).padStart(2, "0");
  return `${year}-${month}-${day}`;
}

export function installInviteStorageKey(userId: string, date = new Date()) {
  return `poorten:pwa-invite:${userId}:${localDateKey(date)}`;
}

export function shouldShowInstallInvite(storage: Pick<Storage, "getItem">, userId: string, date = new Date()) {
  return storage.getItem(installInviteStorageKey(userId, date)) !== "shown";
}
