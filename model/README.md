# Model

Runtime Data Model — describes how PHP-level concepts are represented in memory at a low level.

This includes object layouts, vtables, method dispatch tables, exception structures, closures, and other language mechanisms. This layer sits below the language semantics but above the VM: it defines *what PHP objects look like in memory*, not how they are executed.
