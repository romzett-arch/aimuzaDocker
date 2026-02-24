export interface AnalyzeRequest {
  reportId: string;
}

export interface AIAnalysisResult {
  verdict: "violation" | "clean" | "uncertain";
  confidence: number;
  category: string;
  reason: string;
}
