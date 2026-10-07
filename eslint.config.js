import js from '@eslint/js'
import tsPlugin from '@typescript-eslint/eslint-plugin'
import tsParser from '@typescript-eslint/parser'
import prettierConfig from 'eslint-config-prettier'
import path from 'node:path'
import {fileURLToPath} from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

export default [
    {
        // Build output and QML. The shell loads Model.mjs; it is generated.
        ignores: ['Model.mjs', 'node_modules/**', '*.qml']
    },
    js.configs.recommended,
    {
        files: ['**/*.ts', '**/*.mts', '**/*.tsx'],
        languageOptions: {
            parser: tsParser,
            parserOptions: {
                ecmaVersion: 'latest',
                sourceType: 'module',
                project: true,
                tsconfigRootDir: __dirname
            }
        },
        plugins: {
            '@typescript-eslint': tsPlugin
        },
        rules: {
            ...tsPlugin.configs['flat/recommended-type-checked'][1]?.rules,
            ...tsPlugin.configs['flat/recommended-type-checked'][2]?.rules,
            '@typescript-eslint/no-empty-object-type': 'off',
            '@typescript-eslint/no-base-to-string': 'off',
            '@typescript-eslint/no-unsafe-call': 'warn',
            '@typescript-eslint/no-unsafe-member-access': 'warn',
            '@typescript-eslint/require-await': 'warn',
            '@typescript-eslint/no-unsafe-argument': 'warn',
            '@typescript-eslint/no-misused-promises': 'warn',
            '@typescript-eslint/no-unsafe-enum-comparison': 'warn',
            '@typescript-eslint/no-unused-vars': [
                'warn',
                {
                    varsIgnorePattern: '^_',
                    argsIgnorePattern: '^_'
                }
            ],
            '@typescript-eslint/no-explicit-any': 'error',
            'no-redeclare': 'error',
            '@typescript-eslint/no-shadow': 'error'
        }
    },
    prettierConfig
]
