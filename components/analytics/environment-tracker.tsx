"use client";

import { useEffect } from "react";
import { trackProductAnalytics, type AnalyticsSurface } from "@/lib/analytics/client";

export function EnvironmentTracker({ surface }: { surface: AnalyticsSurface }) {
  useEffect(() => {
    void trackProductAnalytics("environment_opened", surface);
  }, [surface]);
  return null;
}
