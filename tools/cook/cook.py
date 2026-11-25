"""Links a PDF with its Word text into one PDF.
Running without arguments (or with --gui) opens the Tkinter desktop interface.
See README.md.
"""

import sys

if __name__ == '__main__':
    if len(sys.argv) == 1 or '--gui' in sys.argv:
        from nots_cook.gui import main as gui_main
        gui_main()
    else:
        from nots_cook.cli import main
        sys.exit(main())
