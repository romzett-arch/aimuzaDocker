export type Mode = "improve" | "generate" | "create_prompt" | "markup" | "ideas"
  | "suggest_tags" | "build_style" | "analyze_style" | "analyze_prompt" | "auto_tag_all"
  | "fix_pronunciation";

export const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
};

export const MODE_SERVICE_MAP: Record<string, string> = {
  suggest_tags: "prompt_suggest_tags",
  build_style: "prompt_build_style",
  analyze_style: "prompt_check_style",
  analyze_prompt: "prompt_analyzer",
  auto_tag_all: "prompt_suggest_tags",
};

export const DEEPSEEK_AGENT_ID = 'e046a9e4-43f6-47bc-a39f-8a9de8778d02';

export type RequestBody = {
  mode: Mode;
  lyrics?: string;
  style?: string;
  theme?: string;
  userRequest?: string;
  sectionText?: string;
  existingTagIds?: string[];
  availableTags?: Array<{ id: string; tag: string; nameRu: string }>;
  selectedStyleIds?: string[];
  sections?: Array<{ id: string; text: string; tagIds: string[] }>;
  availableStyles?: Array<{ id: string; tag: string; nameRu: string }>;
  taggedText?: string;
  sunoVersion?: string;
  autoEval?: boolean;
};
