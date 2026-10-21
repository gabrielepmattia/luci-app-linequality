include $(TOPDIR)/rules.mk

PKG_NAME:=linequality
PKG_VERSION:=0.2.0
PKG_RELEASE:=1

PKG_LICENSE:=Apache-2.0
PKG_MAINTAINER:=Gabriele Proietti Mattia <pm.gabriele@gmail.com>

include $(INCLUDE_DIR)/package.mk

define Package/linequality
  SECTION:=net
  CATEGORY:=Network
  TITLE:=WAN line quality monitor
  DEPENDS:=+ucode +ucode-mod-fs +ucode-mod-ubus +ucode-mod-uloop +ucode-mod-uci +fping
  URL:=https://github.com/gabrielepmattia/luci-app-linequality
  PKGARCH:=all
endef

define Package/linequality/description
  Collector daemon that records WAN traffic, packet loss, latency, jitter,
  outages and optional speed tests, and exposes them over ubus.
endef

define Package/linequality/conffiles
/etc/config/linequality
endef

define Build/Compile
endef

define Package/linequality/install
	$(INSTALL_DIR) $(1)/usr/share/linequality
	$(INSTALL_BIN) ./files/linequalityd.uc $(1)/usr/share/linequality/linequalityd.uc
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/linequality.init $(1)/etc/init.d/linequality
	$(INSTALL_DIR) $(1)/etc/config
	$(INSTALL_CONF) ./files/linequality.config $(1)/etc/config/linequality
	$(INSTALL_DIR) $(1)/lib/upgrade/keep.d
	$(INSTALL_DATA) ./files/linequality.keep $(1)/lib/upgrade/keep.d/linequality
endef

$(eval $(call BuildPackage,linequality))
