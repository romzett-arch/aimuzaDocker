import { musicDictPart1 } from "./music-dict-part1.ts";
import { musicDictPart2 } from "./music-dict-part2.ts";
import { musicDictPart3 } from "./music-dict-part3.ts";

export const musicDict: Record<string, string> = {
  ...musicDictPart1,
  ...musicDictPart2,
  ...musicDictPart3,
};
