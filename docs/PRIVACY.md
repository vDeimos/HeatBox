# Privacy

HeatBox has no accounts, no analytics and no server. It does not collect or transmit information about you or what you download.

## Connections the app causes

| Connection | When | To where |
| --- | --- | --- |
| Looking up and downloading | When you ask | The website of the link, made by yt-dlp |
| A video's picture | When a link is looked up | Wherever that site hosts it |
| Checking a channel | Only when you press Check now | That channel's site, made by yt-dlp |
| Captions for search | Only while spoken-word search is on | The video's own site, made by yt-dlp, asking for captions only |
| Copying a sign-in | Only when you press the button | One request to YouTube to confirm it works |
| Reading a browser's sign-in | Only when you press "Copy my sign-in", or choose a browser for a download | The cookies of the browser you chose are read on this Mac. "Copy my sign-in" keeps only YouTube's and Google's entries, in a file in your data folder (mode 600). A download that uses a browser's sign-in reads its cookies for that download only; nothing is kept from it |
| Installing or updating tools | Only when you press Install or Update | The addresses in `tools.lock.json` (GitHub for yt-dlp and Deno, martin-riedl.de for FFmpeg), and GitHub's release list for Update yt-dlp. They see an ordinary download request from your address |
| The new-version notice | At launch, **only** if an address was built into your copy | That one address; a plain request for a small file |

There are no others. Nothing is sent to the authors.

## What is kept on your Mac

Records of downloads (title, site, version, file location, link, date), small pictures, followed channels, spoken words if you switch that on, your settings and presets, and a saved sign-in only if you save one. It is all in `~/Library/Application Support/Studio x Phobos`; deleting that folder removes it. None of it leaves your Mac.

## Diagnostics

"Save Diagnostics…" in Settings writes a text file where you choose. It holds versions, where each tool came from, on/off switches, counts of downloads by state and, for failed downloads, the site's name and the error sentence with links and your user name removed. It holds no links, titles, file names or folders. Nothing is sent: you attach it yourself if you choose to.

## Listening to videos

Spoken-word search can listen to videos with no captions using macOS's own recognition, on this Mac only and only on mains power. A Mac that would have to send sound away does not listen at all.
