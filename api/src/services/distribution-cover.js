import sharp from 'sharp';

export const distributionCoverResolution = '3000x3000';

export async function prepareDistributionCover(bytes) {
  return sharp(bytes, { limitInputPixels: 20_000_000 })
    .autoOrient()
    .resize(3000, 3000, { fit: 'cover', position: 'centre', kernel: 'lanczos3' })
    .flatten({ background: '#ffffff' })
    .toColourspace('srgb')
    .jpeg({ quality: 95, chromaSubsampling: '4:4:4' })
    .toBuffer();
}
