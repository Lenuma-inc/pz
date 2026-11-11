// Pure embedded JavaScript: no Node, filesystem, or network APIs.
pz.registerTool({
  name: 'hello',
  description: 'Greet someone without filesystem or network access',
  parameters: {
    type: 'object', properties: { name: { type: 'string' } },
    required: ['name'], additionalProperties: false
  },
  execute(args, ctx) {
    const name = args && typeof args.name === 'string' ? args.name : 'world';
    const count = (ctx.state.get('hello_count') || 0) + 1;
    ctx.state.set('hello_count', count);
    return 'Hello, ' + name + '! Greeting number ' + count + '.';
  }
});
pz.registerCommand('hello', {
  handler(args) { return 'Hello, ' + (args || 'world') + '!'; }
});
pz.on('before_request', () => ({
  systemPromptAppend: '\nThe hello tool provides a local, side-effect-free greeting.\n'
}));
pz.on('tool_call', payload => {
  if (payload && payload.toolName === 'hello' && payload.input && payload.input.name === 'blocked') {
    return { block: true, reason: 'The example guard rejects the name blocked.' };
  }
  return { block: false };
});
