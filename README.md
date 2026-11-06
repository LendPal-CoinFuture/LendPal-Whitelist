# LendPal 白名单与买卖

这个仓库有两份合约。

- `AccessRegistry`：白名单。已经用 UUPS 代理部署在 Sepolia，地址不变：`0x135Fb34eBAd72BB91932E22ff48Fa6963f0e5F9E`
- `OtcTrade`：买卖。当前代码不托管 USDT，双方确认后从付 U 的人钱包直接转出。买卖规则还会根据前端具体业务逻辑变更，现在这份不是最终版。

## 目录

- `contracts/`：两份正式合约
- `contracts/interfaces/`：买卖合约用来问「在不在白名单」的接口
- `contracts/test/`：测试用的 USDT，不用于生产
- `scripts/`：部署和升级脚本
- `test/`：Foundry 测试

## 白名单

身份只有三种：超级管理员、普通管理员、普通地址。超级管理员和普通管理员在产品里都算已经准入，和白名单用户一样。

超级管理员是 `owner`。他可以添加、删除普通管理员，可以删除任何一条白名单，可以升级这份白名单合约。普通管理员默认最多 200 人。超级管理员本人不占这个名额。

普通管理员只能加入自己经手的地址，也只能删除自己加入的地址。批量加入和批量删除一次最多 50 条。其中一条不合法，整笔回滚。管理后台还没有批量入口，函数先留在合约里。

`isWhitelisted` 只回答在或不在。一个地址只能被加入一次。名单里没有「谁邀请了谁」，也没有介绍人或担保额度。

## 买卖

平台开单，写下付 U 的人、收 U 的人、金额和当时的手续费。开单不转钱。双方各自确认，确认也不转钱。两边都确认之后结算：从付 U 的人钱包转两笔，对方收 99%，平台收 1%。合约上不留 USDT。还没结算就取消，钱不动。

白名单只查 `isWhitelisted`。开单时两边都要在。确认时再查点确认的那个人。结算时再查付 U 的人。

手续费默认 1%，最高 5%，开单时锁进这一单。收款地址不能设成买卖合约自己。

已部署的买卖代理 `0x1c0865085D32ad95C730AF0879F0642a48b732c5` 仍是旧的托管版本，升级已经关闭，不会变成这份新代码。新的买卖规则要重新部署。在那之前，合约还会按前端业务再改。

## 本地测试

依赖 Foundry。OpenZeppelin 和 forge-std 在 `lib/`。

```bash
forge test
```

## 部署

把 `.env.example` 复制成 `.env`，填入 Sepolia 的 RPC 和部署私钥。私钥不要提交。

```bash
forge script scripts/DeployAccessRegistry.s.sol --rpc-url sepolia --broadcast
forge script scripts/DeployOtcTrade.s.sol --rpc-url sepolia --broadcast
```

已经部署的白名单代理用 `scripts/UpgradeAccessRegistry.s.sol` 升级，地址保持不变。
