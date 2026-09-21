"use client";

import { useEffect, useRef, useState } from "react";
import { Pause, Play } from "lucide-react";

export function MotionToggle() {
  const [paused, setPaused] = useState(false);
  const [systemReduced, setSystemReduced] = useState(false);

  useEffect(() => {
    const media = matchMedia("(prefers-reduced-motion: reduce)");
    const sync = () => {
      const off = media.matches || localStorage.getItem("poorten-motion") === "off";
      setSystemReduced(media.matches);
      document.documentElement.classList.toggle("motion-off", off);
      setPaused(off);
      window.dispatchEvent(new Event("poorten-motion"));
    };
    sync();
    media.addEventListener("change", sync);
    return () => media.removeEventListener("change", sync);
  }, []);

  const toggle = () => {
    if (systemReduced) return;
    const value = !paused;
    setPaused(value);
    document.documentElement.classList.toggle("motion-off", value);
    localStorage.setItem("poorten-motion", value ? "off" : "on");
    window.dispatchEvent(new Event("poorten-motion"));
  };

  return (
    <button
      className="motion-toggle"
      disabled={systemReduced}
      aria-pressed={paused}
      aria-label={systemReduced ? "Animaties uit volgens je apparaatinstelling" : paused ? "Animaties hervatten" : "Animaties pauzeren"}
      title={systemReduced ? "Je apparaatvoorkeur voor minder beweging is actief" : undefined}
      onClick={toggle}
    >
      {paused ? <Play size={13} /> : <Pause size={13} />}
      <span>{systemReduced ? "Rustige weergave" : paused ? "Beweging uit" : "Beweging aan"}</span>
    </button>
  );
}

export function MotionAtmosphere({ route }: { route: string }) {
  const canvas = useRef<HTMLCanvasElement>(null);
  const progress = useRef<HTMLDivElement>(null);

  useEffect(() => {
    const element = canvas.current;
    const context = element?.getContext("2d");
    if (!element || !context) return;
    let width = innerWidth;
    let height = innerHeight;
    let frame = 0;
    let last = 0;
    let stopped = false;
    const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
    const points = Array.from({ length: innerWidth < 700 ? 12 : 27 }, (_, index) => ({
      x: Math.random() * width,
      y: Math.random() * height,
      radius: 0.5 + Math.random(),
      speed: 0.08 + Math.random() * 0.17,
      phase: index * 0.8,
    }));

    const resize = () => {
      width = innerWidth;
      height = innerHeight;
      const ratio = Math.min(devicePixelRatio, 1.5);
      element.width = width * ratio;
      element.height = height * ratio;
      element.style.width = `${width}px`;
      element.style.height = `${height}px`;
      context.setTransform(ratio, 0, 0, ratio, 0, 0);
    };
    const draw = (time: number) => {
      if (stopped) return;
      frame = requestAnimationFrame(draw);
      if (time - last < 32) return;
      last = time;
      context.clearRect(0, 0, width, height);
      if (document.hidden || reducedMotion.matches || document.documentElement.classList.contains("motion-off")) return;
      for (const point of points) {
        point.y -= point.speed;
        point.x += Math.sin(time * 0.00015 + point.phase) * 0.08;
        if (point.y < 0) {
          point.y = height;
          point.x = Math.random() * width;
        }
        context.beginPath();
        context.arc(point.x, point.y, point.radius, 0, Math.PI * 2);
        context.fillStyle = `rgba(${point.phase % 2 > 1 ? "110,193,213" : "216,165,121"},${0.13 + Math.sin(time * 0.0007 + point.phase) * 0.1})`;
        context.fill();
      }
    };
    const scroll = () => {
      document.querySelector(".site-header")?.classList.toggle("is-scrolled", scrollY > 65);
      if (progress.current) {
        const pageHeight = document.documentElement.scrollHeight - innerHeight;
        progress.current.style.transform = `scaleX(${pageHeight > 0 ? scrollY / pageHeight : 0})`;
      }
    };
    const pointer = (event: PointerEvent) => {
      if (reducedMotion.matches || document.documentElement.classList.contains("motion-off")) return;
      const target = (event.target as HTMLElement).closest<HTMLElement>(".world-card,.portal-list-card,.package-grid button");
      if (!target) return;
      const rectangle = target.getBoundingClientRect();
      const x = (event.clientX - rectangle.left) / rectangle.width;
      const y = (event.clientY - rectangle.top) / rectangle.height;
      target.style.setProperty("--tilt-x", `${(y - 0.5) * -5}deg`);
      target.style.setProperty("--tilt-y", `${(x - 0.5) * 5}deg`);
      target.style.setProperty("--shine-x", `${x * 100}%`);
      target.style.setProperty("--shine-y", `${y * 100}%`);
    };
    const reset = (event: PointerEvent) => {
      const target = (event.target as HTMLElement).closest<HTMLElement>(".world-card,.portal-list-card,.package-grid button");
      target?.style.setProperty("--tilt-x", "0deg");
      target?.style.setProperty("--tilt-y", "0deg");
    };

    resize();
    frame = requestAnimationFrame(draw);
    window.addEventListener("resize", resize);
    window.addEventListener("scroll", scroll, { passive: true });
    document.addEventListener("pointermove", pointer, { passive: true });
    document.addEventListener("pointerout", reset, { passive: true });
    scroll();
    return () => {
      stopped = true;
      cancelAnimationFrame(frame);
      window.removeEventListener("resize", resize);
      window.removeEventListener("scroll", scroll);
      document.removeEventListener("pointermove", pointer);
      document.removeEventListener("pointerout", reset);
    };
  }, []);

  return (
    <>
      <div className="reading-progress" ref={progress} />
      <canvas ref={canvas} className="atmosphere-dust" aria-hidden="true" />
      <div key={route} className="page-light-transition" aria-hidden="true" />
    </>
  );
}
