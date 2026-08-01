const GENERATION_VARIANT_PATTERN = /\[generation_variant:\s*([01])\]/i;
const INTERNAL_TRACK_METADATA_PATTERN =
  /\s*\[(?:task_id|generation_variant):\s*[^\]]*\]\s*/gi;

export function getGenerationVariantIndex(
  description: string | null | undefined,
  title: string | null | undefined,
): number {
  const storedVariant = description?.match(GENERATION_VARIANT_PATTERN)?.[1];
  if (storedVariant === "1") return 1;
  if (storedVariant === "0") return 0;

  // Backward compatibility for tracks created before variants were hidden.
  return /\(v2\)\s*$/.test(title || "") ? 1 : 0;
}

export function stripTrackGenerationMetadata(value: string | null | undefined): string {
  return (value || "").replace(INTERNAL_TRACK_METADATA_PATTERN, " ").trim();
}
