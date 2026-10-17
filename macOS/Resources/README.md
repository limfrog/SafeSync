# SafeSync original artwork

SafeSync.png is the intact 256×256 PNG entry extracted from the Windows app icon at `outputs/SafeSync/SafeSync.ico` in this repository. Its artwork and alpha channel are unchanged. The separate Windows `SafeSync-icon.png` file was not used because its decoded image was incomplete.

`../scripts/build-icons.sh` makes the macOS ICNS sizes from this image using sips and packages the PNG representations in an ICNS container. Large sizes are scaled from the existing 256×256 icon, not newly generated artwork. Python 3 is required by this script.

The same artwork is used for the Finder/Dock icon, the main window header and the menu bar icon.
