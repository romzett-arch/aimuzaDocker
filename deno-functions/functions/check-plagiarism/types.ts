export interface PlagiarismRequest {
  trackId: string;
  audioUrl: string;
}

export interface CheckStep {
  id: string;
  name: string;
  database: string;
  status: 'pending' | 'checking' | 'done' | 'error';
  result?: {
    found: boolean;
    matches?: Array<{
      title: string;
      artist: string;
      similarity: number;
      source: string;
    }>;
  };
}

export interface AcoustIDResult {
  status: string;
  results?: Array<{
    id: string;
    score: number;
    recordings?: Array<{
      id: string;
      title?: string;
      artists?: Array<{ name: string }>;
      duration?: number;
    }>;
  }>;
}

export interface ACRCloudResult {
  status: {
    code: number;
    msg: string;
  };
  metadata?: {
    music?: Array<{
      title: string;
      artists?: Array<{ name: string }>;
      album?: { name: string };
      score: number;
      external_ids?: {
        isrc?: string;
        upc?: string;
      };
    }>;
  };
}

export type PlagiarismMatch = {
  title: string;
  artist: string;
  similarity: number;
  source: string;
};
