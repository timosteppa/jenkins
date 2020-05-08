pipeline {
    agent any
    stages {
        stage('Build') {
            steps {
                sh 'echo "Hello World 2020 Covid"'
                sh 'python --version'
                sh '''
                echo "Multiline shell steps works too"
                ls -lah
                '''
            }
        }
        stage('Test') {
            steps {
                echo 'Testing to see if bigger, hello script works'
                sh 'python helloworld.py'


            }

        }
    }
}
