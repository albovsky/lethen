import PackagePlugin

@main
struct ToolPlugin: CommandPlugin {
    func performCommand(context: PluginContext, arguments _: [String]) async throws {
        _ = try context.tool(named: "UnbuiltTool")
    }
}
