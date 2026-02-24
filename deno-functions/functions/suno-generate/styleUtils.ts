const artistToStyleMap: Record<string, string> = {
  "Drake": "moody trap hip-hop with melodic hooks",
  "The Weeknd": "dark synth-pop R&B with falsetto vocals",
  "Taylor Swift": "catchy pop-country with storytelling lyrics",
  "Ed Sheeran": "acoustic pop folk with romantic themes",
  "Billie Eilish": "dark minimalist pop with whispered vocals",
  "Ariana Grande": "powerful pop R&B with high vocals",
  "Dua Lipa": "disco-influenced dance pop",
  "Bad Bunny": "reggaeton latin trap with urban beats",
  "Post Malone": "melodic hip-hop rock fusion",
  "Kendrick Lamar": "conscious lyrical hip-hop",
  "Beyoncé": "powerful R&B pop with soulful vocals",
  "BTS": "K-pop with dynamic choreography vibes",
  "Harry Styles": "70s inspired soft rock pop",
  "Doja Cat": "playful rap-pop with catchy hooks",
  "SZA": "neo-soul R&B with vulnerable lyrics",
  "Travis Scott": "atmospheric auto-tune trap",
  "Olivia Rodrigo": "emotional pop-rock with teen angst",
  "Lana Del Rey": "cinematic dreamy baroque pop",
  "Kanye West": "experimental hip-hop with gospel influences",
  "Bruno Mars": "funk pop with retro grooves",
  "Adele": "powerful ballads with soulful vocals",
  "Rihanna": "dancehall-influenced pop R&B",
  "Justin Bieber": "pop R&B with tropical influences",
  "Lady Gaga": "theatrical electro-pop",
  "Shakira": "latin pop with world music fusion",
  "Coldplay": "anthemic alternative rock with atmospheric synths",
  "Imagine Dragons": "arena rock with electronic elements",
  "Twenty One Pilots": "alternative hip-hop with electronic elements",
  "Maroon 5": "pop rock with funky grooves",
  "OneRepublic": "orchestral pop rock with uplifting themes",
};

export function convertArtistToStyle(artistName: string): string {
  if (artistToStyleMap[artistName]) {
    return artistToStyleMap[artistName];
  }

  const lowerName = artistName.toLowerCase();
  for (const [artist, style] of Object.entries(artistToStyleMap)) {
    if (artist.toLowerCase() === lowerName) {
      return style;
    }
  }

  return "contemporary pop with modern production";
}

export function cleanStyleForSuno(style: string): string {
  if (!style) return "";

  let cleanedStyle = style;

  for (const artistName of Object.keys(artistToStyleMap)) {
    const regex = new RegExp(`${artistName}\\s*style`, "gi");
    if (regex.test(cleanedStyle)) {
      cleanedStyle = cleanedStyle.replace(regex, convertArtistToStyle(artistName));
    }

    const standaloneRegex = new RegExp(`\\b${artistName}\\b`, "gi");
    if (standaloneRegex.test(cleanedStyle)) {
      cleanedStyle = cleanedStyle.replace(standaloneRegex, convertArtistToStyle(artistName));
    }
  }

  cleanedStyle = cleanedStyle.replace(/,\s*,/g, ",").replace(/\s+/g, " ").trim();

  return cleanedStyle;
}
