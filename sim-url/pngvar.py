"""pngvar.py — pixel-variance discriminator. Prints '<variance> <ncolors>'.

Blank-shell failure mode: near-white screen + back chevron + tab bar =>
low variance, few distinct colors. A rendered ANF article (masthead,
headline, photo, paywall art) => high variance, many colors.
Calibrated (T3, sim A1E4A805): blank shell var=243 colors=218;
24 renders var=2697..12541 colors=888..8880 (monochrome/flat designs lower
colors, still high variance). Cutoff: var>1500 AND colors>500.
"""
import sys
from PIL import Image, ImageStat

im = Image.open(sys.argv[1]).convert("L").resize((200, 400))
st = ImageStat.Stat(im)
small = Image.open(sys.argv[1]).convert("RGB").resize((100, 200))
colors = small.getcolors(100 * 200)
print(f"{st.var[0]:.0f} {len(colors)}")
