# Loaded by script/console. Land helpers here.

Pry.config.prompt = lambda do |context, nesting, pry|
  "[mysql2] #{context}> "
end
