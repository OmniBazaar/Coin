// @ts-check
'use strict';

/** @type {import('eslint').Linter.Config} */
module.exports = {
  root: true,
  parser: '@typescript-eslint/parser',
  parserOptions: {
    ecmaVersion: 2020,
    sourceType: 'module',
    project: './tsconfig.json',
    tsconfigRootDir: __dirname,
  },
  plugins: ['@typescript-eslint', 'jsdoc'],
  extends: [
    'eslint:recommended',
    'plugin:@typescript-eslint/recommended',
    'plugin:@typescript-eslint/recommended-requiring-type-checking',
    'plugin:jsdoc/recommended-typescript',
  ],
  env: {
    node: true,
    es2020: true,
  },
  ignorePatterns: [
    'node_modules/',
    'dist/',
    'artifacts/',
    'cache/',
    'coverage/',
    'typechain-types/',
    'hardhat.config.js',
    'jest.config.js',
    '*.js',
    'scripts/**/*.js',
    'test/**/*.js',
  ],
  rules: {
    // TypeScript
    '@typescript-eslint/no-explicit-any': 'error',
    '@typescript-eslint/no-unused-vars': ['error', { argsIgnorePattern: '^_', varsIgnorePattern: '^_' }],
    '@typescript-eslint/explicit-function-return-type': 'off',
    '@typescript-eslint/explicit-module-boundary-types': 'off',
    '@typescript-eslint/no-floating-promises': 'error',
    '@typescript-eslint/no-misused-promises': 'error',
    '@typescript-eslint/strict-null-checks': 'off',

    // JSDoc
    'jsdoc/require-jsdoc': [
      'warn',
      {
        publicOnly: true,
        require: {
          FunctionDeclaration: true,
          MethodDefinition: true,
          ClassDeclaration: true,
          ArrowFunctionExpression: false,
          FunctionExpression: false,
        },
      },
    ],
    'jsdoc/require-param': 'warn',
    'jsdoc/require-param-description': 'warn',
    'jsdoc/require-param-type': 'off', // TypeScript handles types
    'jsdoc/require-returns': ['warn', { forceReturnsWithAsync: false }],
    'jsdoc/require-returns-type': 'off', // TypeScript handles types
    'jsdoc/require-returns-description': 'warn',
    'jsdoc/require-returns-check': ['warn', { reportMissingReturnForUndefinedTypes: false }],
    'jsdoc/check-param-names': 'warn',
    'jsdoc/check-tag-names': 'warn',

    // General
    'no-console': 'warn',
    'no-unused-vars': 'off', // Use TypeScript version instead
    'prefer-const': 'error',
    'no-var': 'error',
  },
  overrides: [
    {
      // Test files get relaxed rules and use tsconfig.test.json for type info.
      // Hardhat/Mocha test files commonly use:
      //   - require() imports (CommonJS interop with hardhat toolbox)
      //   - Chai assertion chains as expressions (.to.be.reverted, .to.be.true)
      //   - any-typed contract instances from ethers.getContractFactory()
      //   - Unused variables prefixed with _ (destructured-but-unused signers)
      files: ['test/**/*.ts', '**/*.test.ts', '**/*.spec.ts'],
      parserOptions: {
        project: './tsconfig.test.json',
        tsconfigRootDir: __dirname,
      },
      rules: {
        '@typescript-eslint/no-explicit-any': 'warn',
        '@typescript-eslint/no-require-imports': 'off',
        '@typescript-eslint/no-var-requires': 'off',
        // Chai assertions use property chains as async assertions (.to.be.reverted)
        '@typescript-eslint/no-unused-expressions': 'off',
        'no-unused-expressions': 'off',
        // Tests commonly check without awaiting (hardhat-chai-matchers handles async)
        '@typescript-eslint/require-await': 'off',
        'jsdoc/require-jsdoc': 'off',
        'jsdoc/require-param': 'off',
        'jsdoc/require-returns': 'off',
        'no-console': 'off',
        '@typescript-eslint/no-unsafe-member-access': 'off',
        '@typescript-eslint/no-unsafe-call': 'off',
        '@typescript-eslint/no-unsafe-assignment': 'off',
        '@typescript-eslint/no-unsafe-argument': 'off',
        '@typescript-eslint/no-unsafe-return': 'off',
      },
    },
    {
      // Script files get relaxed rules
      files: ['scripts/**/*.ts'],
      rules: {
        'no-console': 'off',
        'jsdoc/require-jsdoc': 'off',
        '@typescript-eslint/no-explicit-any': 'warn',
      },
    },
  ],
};
