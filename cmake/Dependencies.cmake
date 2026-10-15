include(FetchContent)

find_package(PkgConfig REQUIRED)
pkg_check_modules(LIBCURL REQUIRED IMPORTED_TARGET libcurl)
pkg_check_modules(FLAC REQUIRED IMPORTED_TARGET flac)
pkg_check_modules(MPG123 REQUIRED IMPORTED_TARGET libmpg123)
pkg_check_modules(OPUSFILE REQUIRED IMPORTED_TARGET opusfile)
pkg_check_modules(VORBIS REQUIRED IMPORTED_TARGET vorbis)
pkg_check_modules(VORBISFILE REQUIRED IMPORTED_TARGET vorbisfile)
pkg_check_modules(OGG REQUIRED IMPORTED_TARGET ogg)

FetchContent_Declare(yyjson
    GIT_REPOSITORY https://github.com/ibireme/yyjson.git
    GIT_TAG 6447536015f3d600f3d65323b10976103b337ca7
    GIT_SHALLOW FALSE
    SOURCE_SUBDIR src
)

FetchContent_Declare(blake3
    GIT_REPOSITORY https://github.com/BLAKE3-team/BLAKE3.git
    GIT_TAG f3149ec5bb5449af877ba20377a11008ff499fa2
    GIT_SHALLOW FALSE
)

FetchContent_Declare(sha2
    GIT_REPOSITORY https://github.com/amosnier/sha-2.git
    GIT_TAG 565f65009bdd98267361b17d50cddd7c9beb3e6c
    GIT_SHALLOW FALSE
)

FetchContent_Declare(doctest
    GIT_REPOSITORY https://github.com/doctest/doctest.git
    GIT_TAG 2d0a9359a60c51affe2a9bebb1be1dca47868151
    GIT_SHALLOW FALSE
    SOURCE_SUBDIR doctest
)

FetchContent_Declare(qoa
    GIT_REPOSITORY https://github.com/phoboslab/qoa.git
    GIT_TAG bc0589710ff6aa2f50e08fb4d0a815d567bc0f3e
    GIT_SHALLOW FALSE
)

FetchContent_Declare(libxaac
    GIT_REPOSITORY https://github.com/ittiam-systems/libxaac.git
    GIT_TAG 2fbadd57bca46693b7a077bcf1513131106d960c
    GIT_SHALLOW FALSE
    SOURCE_SUBDIR docs
)

FetchContent_Declare(alac
    GIT_REPOSITORY https://github.com/evanriley/alac.git
    GIT_TAG f735d5594a03c2fbbfe39c9c69c1135ba5f1faa6
    GIT_SHALLOW FALSE
)

FetchContent_MakeAvailable(yyjson blake3 sha2 doctest qoa libxaac alac)

add_library(orca_yyjson STATIC "${yyjson_SOURCE_DIR}/src/yyjson.c")
target_compile_definitions(orca_yyjson PRIVATE YYJSON_DISABLE_FILE)
target_include_directories(orca_yyjson SYSTEM PUBLIC "${yyjson_SOURCE_DIR}/src")

add_library(orca_blake3 STATIC
    "${blake3_SOURCE_DIR}/c/blake3.c"
    "${blake3_SOURCE_DIR}/c/blake3_dispatch.c"
    "${blake3_SOURCE_DIR}/c/blake3_portable.c"
)
target_compile_definitions(orca_blake3 PRIVATE
    BLAKE3_USE_NEON=0
    BLAKE3_NO_SSE2
    BLAKE3_NO_SSE41
    BLAKE3_NO_AVX2
    BLAKE3_NO_AVX512
)
target_include_directories(orca_blake3 SYSTEM PUBLIC "${blake3_SOURCE_DIR}/c")

add_library(orca_sha256 STATIC "${sha2_SOURCE_DIR}/sha-256.c")
target_include_directories(orca_sha256 SYSTEM PUBLIC "${sha2_SOURCE_DIR}")

add_library(orca_doctest INTERFACE)
target_include_directories(orca_doctest SYSTEM INTERFACE "${doctest_SOURCE_DIR}")

add_library(orca_flac_shim STATIC "${PROJECT_SOURCE_DIR}/liborca/codec/flac_shim.c")
target_include_directories(orca_flac_shim PRIVATE "${PROJECT_SOURCE_DIR}/liborca/codec")
target_link_libraries(orca_flac_shim PRIVATE PkgConfig::FLAC orca_sanitizers)

add_library(orca_mp3_shim STATIC "${PROJECT_SOURCE_DIR}/liborca/codec/mp3_shim.c")
target_include_directories(orca_mp3_shim PRIVATE "${PROJECT_SOURCE_DIR}/liborca/codec")
target_link_libraries(orca_mp3_shim PRIVATE PkgConfig::MPG123 orca_sanitizers)

add_library(orca_qoa_shim STATIC "${PROJECT_SOURCE_DIR}/liborca/codec/qoa_shim.c")
target_include_directories(orca_qoa_shim PRIVATE "${PROJECT_SOURCE_DIR}/liborca/codec"
                                                         "${qoa_SOURCE_DIR}")
target_link_libraries(orca_qoa_shim PRIVATE orca_sanitizers)

add_library(orca_opus_shim STATIC "${PROJECT_SOURCE_DIR}/liborca/codec/opus_shim.c")
target_include_directories(orca_opus_shim PRIVATE "${PROJECT_SOURCE_DIR}/liborca/codec")
target_link_libraries(orca_opus_shim PRIVATE PkgConfig::OPUSFILE orca_sanitizers)

add_library(orca_vorbis_shim STATIC "${PROJECT_SOURCE_DIR}/liborca/codec/vorbis_shim.c")
target_include_directories(orca_vorbis_shim PRIVATE "${PROJECT_SOURCE_DIR}/liborca/codec")
target_link_libraries(orca_vorbis_shim PRIVATE PkgConfig::VORBISFILE PkgConfig::VORBIS
                                                  PkgConfig::OGG orca_sanitizers)

set(ORCA_LIBXAAC_SOURCES
    "${libxaac_SOURCE_DIR}/common/ixheaac_esbr_fft.c"
    "${libxaac_SOURCE_DIR}/common/ixheaac_esbr_rom.c"
    "${libxaac_SOURCE_DIR}/common/ixheaac_fft_ifft_32x32_rom.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_aacdecoder.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_aacpluscheck.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_aac_ec.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_aac_imdct.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_aac_rom.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_aac_tns.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_acelp_bitparse.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_acelp_decode.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_acelp_mdct.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_acelp_tools.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_adts_crc_check.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_api.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_arith_dec.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_avq_dec.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_avq_rom.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_basic_funcs.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_basic_ops.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_bitbuffer.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_block.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_channel.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_common_initfuncs.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_common_lpfuncs.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_common_rom.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_create.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_decode_main.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_drc_freq_dec.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_dsp_fft32x32s.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_ec_rom.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_env_calc.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_env_dec.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_env_extr.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_esbr_envcal.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_esbr_polyphase.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_ext_ch_ele.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_fft.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_fft_ifft_32x32.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_freq_sca.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_fwd_alias_cnx.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_hbe_dft_trans.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_hbe_trans.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_headerdecode.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_hufftables.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_huff_code_reorder.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_huff_tools.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_hybrid.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_imdct.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_initfuncs.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_init_config.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_latmdemux.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_ld_mps_config.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_ld_mps_dec.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_longblock.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_lpc.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_lpc_dec.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_lpfuncs.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_lpp_tran.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_lt_predict.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_apply_common.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_apply_m1.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_apply_m2.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_bitdec.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_blind.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_calc_m1m2_common.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_calc_m1m2_emm.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_calc_m1m2_tree_515x.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_calc_m1m2_tree_51sx.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_calc_m1m2_tree_52xx.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_calc_m1m2_tree_727x.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_calc_m1m2_tree_757x.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_dec.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_decorr.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_get_index.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_hybrid_filt.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_initfuncs.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_m1m2_common.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_mdct_2_qmf.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_parse.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_polyphase.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_poly_filt.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_pre_mix.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_process.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_reshape_bb_env.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_res_block.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_res_channel.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_res_channel_info.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_res_longblock.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_res_pns_js_thumb.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_res_pulsedata.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_res_tns.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_rom.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_smoothing.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_temp_process.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_temp_reshape.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_mps_tonality.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_multichannel.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_peak_limiter.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_pns_js_thumb.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_pred_vec_block.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_process.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_ps_bitdec.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_ps_dec.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_ps_dec_flt.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_pvc_rom.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_qmf_dec.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_rev_vlc.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_rom.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_sbrdecoder.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_sbrdec_initfuncs.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_sbrdec_lpfuncs.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_sbr_crc.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_sbr_dec.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_sbr_rom.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_spectrum_dec.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_stereo.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_tcx_fwd_alcnx.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_tcx_fwd_mdct.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_thumb_ps_dec.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_tns.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_usac_ec.c"
    "${libxaac_SOURCE_DIR}/decoder/ixheaacd_Windowing.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_api.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_bitbuffer.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_dec.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_dynamic_payload.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_eq.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_extr_delta_coded_info.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_filter_bank.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_gain_dec.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_gain_decoder.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_init.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_interface_decoder.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_loudness_control.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_main_td_process.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_multiband.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_parametric_dec.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_peak_limiter.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_process.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_rom.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_selection_process.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_selection_process_drcset_selection.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_selection_process_init.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_shape_filter.c"
    "${libxaac_SOURCE_DIR}/decoder/drc_src/impd_drc_static_payload.c"
    "${libxaac_SOURCE_DIR}/decoder/x86/ixheaacd_function_selector_x86.c"
    "${libxaac_SOURCE_DIR}/decoder/generic/ixheaacd_qmf_dec_generic.c"
)

add_library(orca_libxaac STATIC ${ORCA_LIBXAAC_SOURCES})
target_include_directories(orca_libxaac PUBLIC
    "${libxaac_SOURCE_DIR}/common"
    "${libxaac_SOURCE_DIR}/decoder"
    "${libxaac_SOURCE_DIR}/decoder/drc_src"
)
target_compile_definitions(orca_libxaac PRIVATE NDEBUG LOUDNESS_LEVELING_SUPPORT)
target_compile_options(orca_libxaac PRIVATE -std=gnu99 -fwrapv -w -fno-sanitize=undefined)

add_library(orca_alac STATIC
    "${alac_SOURCE_DIR}/codec/ag_dec.c"
    "${alac_SOURCE_DIR}/codec/ALACBitUtilities.c"
    "${alac_SOURCE_DIR}/codec/dp_dec.c"
    "${alac_SOURCE_DIR}/codec/EndianPortable.c"
    "${alac_SOURCE_DIR}/codec/matrix_dec.c"
    "${alac_SOURCE_DIR}/codec/ALACDecoder.cpp"
)
target_include_directories(orca_alac PUBLIC "${alac_SOURCE_DIR}/codec")
target_compile_definitions(orca_alac PRIVATE NDEBUG)
target_link_libraries(orca_alac PRIVATE orca_sanitizers)
set_source_files_properties(
    "${alac_SOURCE_DIR}/codec/ag_dec.c"
    "${alac_SOURCE_DIR}/codec/ALACBitUtilities.c"
    "${alac_SOURCE_DIR}/codec/dp_dec.c"
    "${alac_SOURCE_DIR}/codec/EndianPortable.c"
    "${alac_SOURCE_DIR}/codec/matrix_dec.c"
    PROPERTIES COMPILE_OPTIONS "-std=c99;-fno-sanitize=shift-base;-fwrapv;-w")
set_source_files_properties("${alac_SOURCE_DIR}/codec/ALACDecoder.cpp" PROPERTIES
    COMPILE_OPTIONS "-std=c++11;-fno-exceptions;-fno-rtti;-fno-sanitize=shift-base;-fwrapv;-w")

add_library(orca_aac_shim STATIC "${PROJECT_SOURCE_DIR}/liborca/codec/aac_shim.c")
target_include_directories(orca_aac_shim PRIVATE "${PROJECT_SOURCE_DIR}/liborca/codec")
target_link_libraries(orca_aac_shim PRIVATE orca_libxaac orca_sanitizers)
target_compile_options(orca_aac_shim PRIVATE -Wall -Wextra)

add_library(orca_alac_shim STATIC "${PROJECT_SOURCE_DIR}/liborca/codec/alac_shim.cpp")
target_include_directories(orca_alac_shim PRIVATE "${PROJECT_SOURCE_DIR}/liborca/codec"
                                                       "${alac_SOURCE_DIR}/codec")
target_compile_options(orca_alac_shim PRIVATE -fno-exceptions -fno-rtti)
target_link_libraries(orca_alac_shim PRIVATE orca_alac orca_sanitizers)

