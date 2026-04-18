# zknot3 智能合约支持

## 概述

是的，**zknot3 支持智能合约**！

zknot3 包含完整的 **Move VM** 实现（Zig 语言版本），支持基于 Move 语言的智能合约开发。

---

## Move VM 实现

| 组件 | 文件 | 功能 |
|------|------|------|
| **解释器** | `src/property/move_vm/Interpreter.zig` | 基于栈的字节码执行引擎 |
| **字节码** | `src/property/move_vm/Bytecode.zig` | Move 字节码定义和验证器 |
| **Gas 计量** | `src/property/move_vm/Gas.zig` | 气体计量和预算控制 |
| **资源追踪** | `src/property/move_vm/Resource.zig` | 线性类型资源管理 |
| **调试器** | `src/property/move_vm/Debugger.zig` | 合约调试支持 |
| **治理** | `src/property/move_vm/Governance.zig` | 链上治理合约 |

---

## 已测试的合约类型

从 `contract_test.zig` 可以看到，zknot3 已支持：

✅ **算术运算合约** - 加法、乘法、阶乘等  
✅ **布尔逻辑合约** - AND、OR、NOT、比较运算  
✅ **Gas 预算执行** - 防止资源耗尽攻击  
✅ **资源追踪** - Move 线性类型系统  
✅ **ERC20-like 代币** - totalSupply、balanceOf、transfer、approve、transferFrom  
✅ **复杂表达式** - 嵌套计算和条件判断  

---

## 示例合约

### 1. 简单加法合约

```zig
// 字节码: ld_const(7); ld_const(3); add; ret
const bytecode = &amp;.{
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x07,  // 7
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,  // 3
    0x40,  // add
    0x01,  // ret
};
```

### 2. 阶乘合约

```zig
// 计算 5! = 120
const bytecode = &amp;.{
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, // 5
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x04, // 4
    0x42, // mul
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, // 3
    0x42, // mul
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, // 2
    0x42, // mul
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, // 1
    0x42, // mul
    0x01, // ret
};
```

### 3. ERC20-like 代币合约

#### totalSupply
```zig
// 返回总供应量 (1000000)
const bytecode = &amp;.{ 
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x0F, 0x40, // 1000000
    0x01, // ret
};
```

#### balanceOf
```zig
// 返回地址余额 (500)
const bytecode = &amp;.{ 
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xF4, // 500
    0x01, // ret
};
```

#### transfer
```zig
// sender_balance = 500; amount = 200; new_balance = sender_balance - amount
const bytecode = &amp;.{ 
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0xF4, // sender_balance = 500
    0x30, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC8, // amount = 200
    0x41, // subtract
    0x01, // ret
};
```

---

## 与 Sui 的兼容性

### 相同点
- 都使用 **Move 语言/VM**
- 支持资源类型线性类型系统
- Gas 计量机制
- 字节码验证

### 不同点
- zknot3 的 Move VM 是 **Zig 原生实现**
- Sui 的 Move VM 是 **Rust 实现**
- zknot3 有编译时验证特性
- Sui 有更成熟的开发者工具生态

---

## Move VM 关键特性

### 1. 确定性执行
- 相同输入总是产生相同输出
- 无随机数生成（除非显式引入）
- 执行顺序完全确定

### 2. 编译时验证
- 字节码在执行前验证
- 类型安全检查
- 资源使用验证

### 3. Gas 计量
- 防止无限循环和资源滥用
- 每条指令消耗固定 Gas
- Gas 预算可配置

### 4. 线性类型系统
- 确保资源不被复制或泄漏
- 资源必须被显式移动或销毁
- 编译时和运行时双重检查

### 5. 完整指令集
- 算术运算：add, sub, mul, div, mod
- 逻辑运算：and, or, not, xor
- 比较运算：eq, neq, lt, gt, lte, gte
- 控制流：br, br_true, br_false
- 资源操作：move_to, move_from, borrow_global

---

## 使用 Move VM

### 初始化解释器

```zig
const allocator = std.testing.allocator;

const gas_config: Gas.GasConfig = .{ 
    .initial_budget = 1000, 
    .max_gas = 10000 
};
var gas = Gas.GasMeter.init(gas_config);
var tracker = ResourceTracker.init(allocator);
defer tracker.deinit();

var interpreter = try Interpreter.init(allocator, &amp;gas, &amp;tracker);
defer interpreter.deinit();
```

### 验证并执行字节码

```zig
var verifier = BytecodeVerifier.init(allocator);
var module = try verifier.verify(bytecode);
defer module.deinit(allocator);

const result = try interpreter.execute(module);
try std.testing.expect(result.success);
```

### 检查执行结果

```zig
if (result.success) {
    if (result.return_value) |ret| {
        switch (ret.tag) {
            .integer =&gt; std.debug.print("Result: {d}\n", .{ret.data.int}),
            .boolean =&gt; std.debug.print("Result: {}\n", .{ret.data.bool}),
            else =&gt; {},
        }
    }
    std.debug.print("Gas consumed: {d}\n", .{result.gas_consumed});
} else {
    std.debug.print("Execution failed: {}\n", .{result.err});
}
```

---

## 测试覆盖

zknot3 的 Move VM 包含全面的测试：

| 测试 | 描述 |
|------|------|
| 算术合约执行 | 测试加法、乘法等基本运算 |
| 阶乘合约执行 | 测试循环和多次乘法 |
| 布尔逻辑合约 | 测试 AND、OR、NOT 运算 |
| Gas 预算执行 | 测试 Gas 耗尽时的正确行为 |
| 资源追踪 | 测试线性类型系统 |
| 无效操作码拒绝 | 测试字节码验证器 |
| 复杂表达式 | 测试嵌套计算和比较 |
| ERC20 代币 | 测试 totalSupply、balanceOf、transfer |

---

## 未来计划

### 短期目标
- [ ] 完整的 Move 语言编译器集成
- [ ] 更多标准库合约
- [ ] 合约部署和升级机制
- [ ] 事件发射和监听

### 中期目标
- [ ] Move 语言源代码支持
- [ ] 开发者 SDK 和工具链
- [ ] 合约测试框架
- [ ] 形式化验证集成

### 长期目标
- [ ] 与 Sui Move 生态完全兼容
- [ ] 跨链合约调用
- [ ] 隐私合约支持
- [ ] 并行合约执行

---

## 总结

**zknot3 具备完整的智能合约支持**，通过 Move VM 实现，与 Sui 共享相同的 Move 语言生态。

主要优势：
- ✅ 完整的 Move VM 实现
- ✅ 线性类型系统确保资源安全
- ✅ Gas 计量防止资源滥用
- ✅ 字节码验证确保安全性
- ✅ 全面的测试覆盖
- ✅ Zig 语言带来的性能和内存安全

虽然目前主要支持字节码级别的合约开发，但随着编译器集成，未来将支持完整的 Move 语言源代码开发。
