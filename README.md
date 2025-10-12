## **Realm 精简版**

## 适配标准版以及LXC、KVM等虚拟化的Debian/CentOS/Ubuntu和Alpine，同时支持Docker容器虚拟化的Debian、Alpine，仅在上述系统中测试使用。
## 重要提示：通过Docker容器虚拟化出来的系统有个小bug，重启机器后，需要重新进入脚本，重启一遍启动所有规则，才能正常使用。

## **✨ 功能特性**
- **灵活配置: 可设置监听所有 IP 地址或绑定到特定的IP和端口。**
- **TCP & UDP 支持: 轻松配置 TCP 和 UDP 协议的转发规则。**

### **使用以下命令运行脚本**

**快捷命令：sb**

```
(curl -LfsS https://raw.githubusercontent.com/0xdabiaoge/singbox-lite/main/singbox.sh -o /usr/local/bin/sb || wget -q https://raw.githubusercontent.com/0xdabiaoge/singbox-lite/main/singbox.sh -O /usr/local/bin/sb) && chmod +x /usr/local/bin/sb && sb
```

## **免责声明**
- **本项目仅供学习与技术交流，请在下载后 24 小时内删除，禁止用于商业或非法目的。**
- **使用本脚本所搭建的服务，请严格遵守部署服务器所在地、服务提供商和用户所在国家/地区的相关法律法规。**
- **对于任何因不当使用本脚本而导致的法律纠纷或后果，脚本作者及维护者概不负责。**
