# ad_rop_wpix_tb file list (path 1 results are ad_rop_fblend's and not checked here).
rtl/common/ad_unorm2f.v
rtl/common/ad_f2unorm.v
rtl/rop/ad_fmt_info.v
rtl/rop/ad_fmt_pack.v
rtl/rop/wpix/ad_wpix_place.v
rtl/rop/wpix/ad_wpix_old.v
rtl/rop/ad_rop_wpix.v
# ad_rop_fblend: the real block (rtl/rop/ad_rop_fblend.v, passes these TBs on 2026-11-08).
# Fallback if it breaks: replace the lines below by sim/common/ad_rop_fblend_stub.v.
rtl/common/ad_fp_add.v
rtl/common/ad_fp_mul.v
rtl/common/ad_fp_cmp.v
rtl/rop/ad_rop_fblend.v
rtl/rop/fblend/ad_fblend_clamp.v
rtl/rop/fblend/ad_fblend_combine.v
rtl/rop/fblend/ad_fblend_f2h.v
rtl/rop/fblend/ad_fblend_factor.v
rtl/rop/fblend/ad_fblend_h2f.v
rtl/rop/fblend/ad_fblend_minmax.v
rtl/rop/fblend/ad_fblend_pack.v
rtl/rop/fblend/ad_fblend_srgb_enc.v
rtl/rop/fblend/ad_fblend_srgb_lut.v
rtl/rop/fblend/ad_fblend_unpack.v
