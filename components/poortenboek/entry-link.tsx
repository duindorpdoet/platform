"use client";
import { useEffect, useState } from "react";
import { BookOpen } from "lucide-react";
export function PoortenboekLink({ menu = false }: { menu?: boolean }) {
  const [active, setActive] = useState(false);
  useEffect(() => {
    let live = true;
    void fetch("/api/poortenboek/entry", { cache: "no-store" })
      .then((response) => (response.ok ? response.json() : null))
      .then((data) => {
        if (live) setActive(Boolean(data?.authenticated));
      })
      .catch(() => {});
    return () => {
      live = false;
    };
  }, []);
  return (
    <a
      className={menu ? "poortenboek-menu-link" : "poortenboek-header-link"}
      href={active ? "/poortenboek" : "/poortenboek/inloggen"}
    >
      <BookOpen size={17} />
      Poortenboek
    </a>
  );
}
