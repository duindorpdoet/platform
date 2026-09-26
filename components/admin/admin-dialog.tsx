"use client";

import { useEffect, useRef, type ReactNode } from "react";

export function AdminDialog({
  labelledBy,
  close,
  children,
}: {
  labelledBy: string;
  close: () => void;
  children: ReactNode;
}) {
  const dialogRef = useRef<HTMLDialogElement>(null);
  useEffect(() => {
    const dialog = dialogRef.current;
    if (!dialog) return;
    const opener = document.activeElement as HTMLElement | null;
    const overflow = document.body.style.overflow;
    dialog.showModal();
    dialog.querySelector<HTMLElement>("[data-initial-focus]")?.focus();
    document.body.style.overflow = "hidden";
    return () => {
      dialog.close();
      document.body.style.overflow = overflow;
      if (opener?.isConnected) opener.focus();
    };
  }, []);
  return (
    <dialog
      ref={dialogRef}
      className="group-create-dialog"
      aria-labelledby={labelledBy}
      aria-modal="true"
      onCancel={(event) => {
        event.preventDefault();
        close();
      }}
      onKeyDown={(event) => {
        if (event.key !== "Tab") return;
        const focusable = [
          ...event.currentTarget.querySelectorAll<HTMLElement>(
            'button:not(:disabled), input:not(:disabled), select:not(:disabled), textarea:not(:disabled), a[href], [tabindex="0"]',
          ),
        ];
        const first = focusable[0];
        const last = focusable.at(-1);
        if (event.shiftKey && document.activeElement === first) {
          event.preventDefault();
          last?.focus();
        } else if (!event.shiftKey && document.activeElement === last) {
          event.preventDefault();
          first?.focus();
        }
      }}
      onClick={(event) => {
        if (event.target !== event.currentTarget) return;
        const rect = event.currentTarget.getBoundingClientRect();
        if (
          event.clientX < rect.left ||
          event.clientX > rect.right ||
          event.clientY < rect.top ||
          event.clientY > rect.bottom
        )
          close();
      }}
    >
      {children}
    </dialog>
  );
}
