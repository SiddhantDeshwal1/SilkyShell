#!/usr/bin/env python3
"""
theme_icons.py — Bridge forwarding icon theming calls to theme_kora.py.
"""
from theme_kora import (
    apply_kora_theme,
    apply_icon_theme,
    generate_kora_theme,
    prune_old_themes,
    get_current_icon_theme,
    update_gtk_settings,
    set_gsettings_icon_theme,
    main,
)

if __name__ == "__main__":
    import sys
    sys.exit(main())
