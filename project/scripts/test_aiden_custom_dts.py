#!/usr/bin/env python3
"""Checks for the Aiden SCH v1 (RV1106) board adaptation.

The custom board was migrated from the Luckfox Pico Zero reference design;
this validates the selected device tree and the AIC8800D80 SDIO/BT integration
that boots alongside it.
"""
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
DTS = ROOT / "sysdrv/source/kernel/arch/arm/boot/dts/rv1106g-aiden-custom.dts"
BOARD_CONFIG = (
    ROOT
    / "project/cfg/BoardConfig_IPC"
    / "BoardConfig-EMMC-Buildroot-RV1106_Luckfox_Pico_Zero-IPC.mk"
)
WIFI_MAKEFILE = ROOT / "sysdrv/drv_ko/wifi/Makefile"
WIFI_LOADER = ROOT / "sysdrv/drv_ko/wifi/insmod_wifi.sh"
WIFI_START = ROOT / "project/app/wifi_app/bin/wifi_start.sh"
BT_INIT = (
    ROOT
    / "project/cfg/BoardConfig_IPC/overlay/overlay-luckfox-buildroot-init"
    / "etc/init.d/S99hciinit"
)
AIDEN_BT_CONFIG = (
    ROOT
    / "project/cfg/BoardConfig_IPC/overlay/overlay-luckfox-buildroot-aiden"
    / "etc/default/aic8800-bt"
)
AIDEN_WIFI_INIT = (
    ROOT
    / "project/cfg/BoardConfig_IPC/overlay/overlay-luckfox-buildroot-aiden"
    / "etc/init.d/S26wifi"
)
AIC_FW_DIR = ROOT / "sysdrv/drv_ko/wifi/aic8800dc/aic8800dc_fw"


class AidenCustomBoardTest(unittest.TestCase):
    def setUp(self):
        self.dts = DTS.read_text()

    def test_board_config_selects_the_aiden_dts(self):
        text = BOARD_CONFIG.read_text()
        self.assertIn("export RK_KERNEL_DTS=rv1106g-aiden-custom.dts", text)
        self.assertIn("export RK_ENABLE_WIFI_CHIP=AIC8800D80", text)
        self.assertIn("rv1106-sdiowifi.config", text)

    def test_power_management_i2c_nodes(self):
        # The MP2720 charger is not wired to the RV1106 and must not be
        # described in the board device tree.
        self.assertNotIn("charger@4b", self.dts)
        self.assertNotIn('compatible = "mps,mp2720";', self.dts)
        self.assertIn("bq27220: fuel-gauge@55", self.dts)
        self.assertIn('compatible = "ti,bq27220";', self.dts)
        self.assertIn("vcc3v3_sd: vcc3v3-sd-regulator", self.dts)
        self.assertIn("v_wifi_vcc: v-wifi-vcc", self.dts)

    def test_rk628_moved_to_i2c3_and_tc358743_removed(self):
        self.assertIn("rk628: rk628@50", self.dts)
        self.assertIn('compatible = "rockchip,rk628-csi-v4l2";', self.dts)
        self.assertIn("reset-gpios = <&gpio1 RK_PB0 GPIO_ACTIVE_LOW>;", self.dts)
        self.assertIn("interrupts = <RK_PB1 IRQ_TYPE_LEVEL_HIGH>;", self.dts)
        self.assertIn("pinctrl-0 = <&i2c3m1_xfer>;", self.dts)
        self.assertNotIn("tc358743", self.dts)
        self.assertNotIn("out_osc_tc358743", self.dts)
        # I2C3 owns the bridge, the legacy I2C4 bus is turned off.
        i2c3 = self.dts.index("&i2c3")
        self.assertIn("rk628@50", self.dts[i2c3 : self.dts.index("&i2c4")])
        self.assertIn('&i2c4 {\n\tstatus = "disabled";', self.dts)

    def test_tf_card_on_sdmmc0(self):
        self.assertIn("vmmc-supply = <&vcc3v3_sd>;", self.dts)
        self.assertIn("cd-gpios = <&gpio3 RK_PA1 GPIO_ACTIVE_LOW>;", self.dts)
        self.assertIn(
            "pinctrl-0 = <&sdmmc0_clk &sdmmc0_cmd &sdmmc0_bus4 &sdmmc0_det>;",
            self.dts,
        )

    def test_bluetooth_on_uart0_with_hardware_flow_control(self):
        self.assertIn(
            "pinctrl-0 = <&uart0m1_xfer &uart0m1_ctsn &uart0m1_rtsn>;", self.dts
        )
        # The legacy UART1 Bluetooth binding must be gone.
        self.assertNotIn("&uart1 {", self.dts)
        self.assertNotIn("uart1_gpios", self.dts)

    def test_wifi_on_sdio_controller(self):
        self.assertIn("supports-sdio;", self.dts)
        self.assertIn("non-removable;", self.dts)
        self.assertIn("cap-sdio-irq;", self.dts)
        self.assertIn("keep-power-in-suspend;", self.dts)
        self.assertIn("rockchip,default-sample-phase = <90>;", self.dts)
        self.assertIn(
            "pinctrl-0 = <&sdmmc1m0_cmd &sdmmc1m0_clk &sdmmc1m0_bus4>;",
            self.dts,
        )

    def test_aic8800d80_sdio_driver_path(self):
        makefile = WIFI_MAKEFILE.read_text()
        loader = WIFI_LOADER.read_text()
        wifi_start = WIFI_START.read_text()
        self.assertIn("AIC8800DC AIC8800D80", makefile)
        for sdio_id in ("C08D", "0082"):
            self.assertIn(sdio_id, loader)
            self.assertIn(sdio_id, wifi_start)
        self.assertNotIn("C18D", loader)
        self.assertNotIn("C18D", wifi_start)

    def test_aic8800d80_firmware_is_packaged(self):
        required = {
            "aic_userconfig_8800d80.txt",
            "fmacfw_8800d80_u02.bin",
            "fmacfw_8800d80_h_u02.bin",
            "fw_adid_8800d80_u02.bin",
            "fw_patch_8800d80_u02.bin",
            "fw_patch_8800d80_u02_ext0.bin",
            "fw_patch_table_8800d80_u02.bin",
            "lmacfw_rf_8800d80_u02.bin",
        }
        self.assertTrue(required.issubset({p.name for p in AIC_FW_DIR.iterdir()}))

    def test_aiden_wifi_and_bt_init_order(self):
        wifi_init = AIDEN_WIFI_INIT.read_text()
        bt_init = BT_INIT.read_text()
        bt_config = AIDEN_BT_CONFIG.read_text()
        self.assertIn("/oem/usr/ko/insmod_wifi.sh", wifi_init)
        self.assertIn("/etc/default/aic8800-bt", bt_init)
        self.assertIn("AIC8800_BT_TTY", bt_init)
        self.assertIn("AIC8800_BT_TTY=/dev/ttyS0", bt_config)

    def test_audio_and_voice_module(self):
        self.assertIn("spk-con-gpios = <&gpio3 RK_PC0 GPIO_ACTIVE_HIGH>;", self.dts)
        self.assertIn("pinctrl-0 = <&uart2m1_xfer>;", self.dts)
        self.assertIn("pinctrl-0 = <&uart3m1_xfer>;", self.dts)
        self.assertIn("&uart3 {", self.dts)

    def test_gd32_mcu_interface_nodes(self):
        # RV_HOLD lets the SoC take over VCC5V0_SYS from the companion MCU.
        self.assertIn("mcu_control {", self.dts)
        self.assertIn('label = "rv-hold";', self.dts)
        self.assertIn("gpios = <&gpio0 RK_PA3 GPIO_ACTIVE_HIGH>;", self.dts)
        # RECOVERY is surfaced as a KEY_VENDOR gpio-key.
        self.assertIn("gpio-keys {", self.dts)
        self.assertIn('label = "recovery";', self.dts)
        self.assertIn("linux,code = <KEY_VENDOR>;", self.dts)
        self.assertIn("gpios = <&gpio4 RK_PC0 GPIO_ACTIVE_LOW>;", self.dts)
        self.assertIn("debounce-interval = <100>;", self.dts)
        # GPIO4_C0 is taken over from the EVB SARADC volume keys.
        self.assertIn('adc-keys {\n\t\tstatus = "disabled";', self.dts)

    def test_uart3_m1_uses_soc_function_index(self):
        # RV1106 selects UART3_M1 on GPIO1_D0/D1 with function index 5.
        self.assertIn(
            "<1 RK_PD0 5 &pcfg_pull_none>,\n\t\t\t\t/* gpio1_d1 -> UART3_RX_M1 */\n\t\t\t\t<1 RK_PD1 5 &pcfg_pull_none>;",
            self.dts,
        )


if __name__ == "__main__":
    unittest.main()
