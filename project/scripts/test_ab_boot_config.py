#!/usr/bin/env python3
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
UBOOT = ROOT / "../sysdrv/source/uboot/u-boot"
BOARD_CONFIG = ROOT / "cfg/BoardConfig_IPC/BoardConfig-EMMC-Buildroot-RV1106_Luckfox_Pico_Zero-IPC.mk"
FIT_C = UBOOT / "arch/arm/mach-rockchip/fit.c"
AB_CONFIG = UBOOT / "configs/rv1106-ab.config"
BUILD_SH = ROOT / "build.sh"


class ABBootConfigTest(unittest.TestCase):
    def test_board_enables_uboot_ab_fragment(self):
        text = BOARD_CONFIG.read_text()
        self.assertIn("rv1106-ab.config", text)

    def test_uboot_ab_fragment_enables_required_symbols(self):
        text = AB_CONFIG.read_text()
        for symbol in [
            "CONFIG_ANDROID_AB=y",
            "CONFIG_AVB_LIBAVB_AB=y",
            "CONFIG_AVB_LIBAVB_USER=y",
            "CONFIG_AVB_LIBAVB=y",
            "CONFIG_RK_AVB_LIBAVB_USER=y",
        ]:
            self.assertIn(symbol, text)

    def test_fit_loader_uses_current_ab_boot_slot(self):
        text = FIT_C.read_text()
        self.assertIn("rk_avb_append_part_slot(PART_BOOT", text)
        self.assertIn("No %s partition", text)

    def test_ab_build_removes_unslotted_boot_image(self):
        text = BUILD_SH.read_text()
        self.assertIn("rm -f $RK_PROJECT_OUTPUT_IMAGE/boot.img", text)


if __name__ == "__main__":
    unittest.main()
