/*
 * SPDX-License-Identifier:     GPL-2.0+
 *
 * (C) Copyright 2022 Rockchip Electronics Co., Ltd
 */

#include <common.h>
#include <asm/io.h>
#include <dwc3-uboot.h>
#include <g_dnl.h>
#include <rockusb.h>
#include <usb.h>

DECLARE_GLOBAL_DATA_PTR;

#define CRU_BASE		0xFF3B2000
#define CRU_SOFTRST_CON04	0x0A10
#define USB2PHY_APB_BASE	0xFF3E0000
#define USB2PHY_HS_ODT		0x011C

#ifdef CONFIG_USB_DWC3
static struct dwc3_device dwc3_device_data = {
	.maximum_speed = USB_SPEED_HIGH,
	.base = 0xffb00000,
	.dr_mode = USB_DR_MODE_PERIPHERAL,
	.index = 0,
	.dis_u2_susphy_quirk = 1,
	.usb2_phyif_utmi_width = 16,
};

int usb_gadget_handle_interrupts(int index)
{
	dwc3_uboot_handle_interrupt(0);
	return 0;
}

#ifdef CONFIG_SUPPORT_USBPLUG
static void usb_reset_otg_controller(void)
{
	writel(0x1 << 7 | 0x1 << 23, CRU_BASE + CRU_SOFTRST_CON04);
	mdelay(1);
	writel(0x0 << 7 | 0x1 << 23, CRU_BASE + CRU_SOFTRST_CON04);

	mdelay(1);
}
#endif

int board_usb_init(int index, enum usb_init_type init)
{
	u32 reg;

#ifdef CONFIG_SUPPORT_USBPLUG
	usb_reset_otg_controller();
#endif
	writel(0x01ff0000, 0xff000050); /* Resume usb2 phy to normal mode */

	/*
	 * Match the 45ohm HS ODT trim rv1106_usb2phy_tuning() applies under
	 * Linux. The stock value does not train the link on every host, and a
	 * loader that enumerates differently from the running system is a trap
	 * when the two are compared during a USB fault.
	 */
	reg = readl(USB2PHY_APB_BASE + USB2PHY_HS_ODT);
	reg = (reg & ~GENMASK(4, 0)) | 0x1f;
	writel(reg, USB2PHY_APB_BASE + USB2PHY_HS_ODT);

	return dwc3_uboot_init(&dwc3_device_data);
}

#ifdef CONFIG_USB_GADGET_DOWNLOAD
int g_dnl_board_usb_cable_connected(void)
{
	/*
	 * This is a USB device port and the download key is the operator's
	 * cable-present signal. Keeping this true prevents a transient host
	 * reset or slow enumeration from falling through to BootROM, which
	 * would discard the tuned PHY setting.
	 */
	return 1;
}
#endif
#endif
