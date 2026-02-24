export interface ProcessMasterRequest {
  trackId: string;
  masterAudioUrl: string;
}

export const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

export const PROCESSING_STAGES = [
  { id: 'validating', name: 'Проверка формата WAV 24-bit' },
  { id: 'upscale_detection', name: 'Детектор апскейла (спектральный анализ)' },
  { id: 'loudness_analysis', name: 'Анализ громкости (LUFS)' },
  { id: 'normalization', name: 'Нормализация до -14 LUFS' },
  { id: 'metadata_cleaning', name: 'Очистка и запись метаданных' },
  { id: 'blockchain_hash', name: 'Запись хеша в Blockchain (OpenTimestamps)' },
  { id: 'certificate_generation', name: 'Генерация сертификата' },
  { id: 'gold_pack_assembly', name: 'Сборка Золотого пакета' },
];
