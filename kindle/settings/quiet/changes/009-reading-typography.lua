-- Research-backed "Standard" reading text (docs/design.md, "Reading text"; summary):
--  * size: Bookerly 22 -> 47 px em, x-height 24 px = 2.0 mm = 0.33 deg at 35 cm; fluent reading needs >= 0.2 deg,
--    the target band is 0.30-0.35 deg (Legge & Bigelow 2011; screen studies favour ~20% above book print)
--  * line height 1.45 em for every font (Chung 2004: gains up to ~1.2-1.5x single; extremes hurt, Rello 2016)
--  * side margins 25 units = 4.5 mm -> ~52 characters per line (Dyson & Haselgrove 2001; Tinker ~52; Bringhurst 45-75)
--  * justified + hyphenated (KOReader default; costs only shown for crude or unhyphenated justification), 1.2 em indents
--  * normal weight and contrast; black on white (Piepenbrock 2013/2014)
--  * Bookerly: no font is best for everyone (Wallace 2022); Kindle readers know Bookerly; familiarity helps
--    (Beier & Larson 2013). Publisher fonts off so every book uses it.
return {
    note = "reading text: Bookerly 22, line height 1.45, margins 25/15/15, justified, embedded fonts off",
    reader = {
        cre_font = "Bookerly",
        copt_font_size = 22,
        copt_line_spacing = 100,
        copt_h_page_margins = { 25, 25 },
        copt_t_page_margin = 15,
        copt_b_page_margin = 15,
        copt_font_base_weight = 0,
        copt_font_gamma = 15,
        copt_word_expansion = 0,
        copt_embedded_fonts = 0,
        ["style_tweaks.lineheight_all_inherit"] = true,
        ["style_tweaks.normal_line-height_145"] = true,
        ["style_tweaks.font_size_most_reset"] = true,
        quiet_look = "standard",
    },
    books = {
        strip = { "font_face", "copt_font_size", "copt_line_spacing", "copt_h_page_margins", "copt_t_page_margin",
            "copt_b_page_margin", "copt_font_base_weight", "copt_font_gamma", "copt_word_expansion", "copt_word_spacing",
            "copt_embedded_fonts" },
    },
}
